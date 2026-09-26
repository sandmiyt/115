#include "CinevaVideoOutput.h"
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>
#include <errno.h>
#include <math.h>

static const uint8_t *metadata(AVFrame *frame, const AVCodecParameters *params,
    enum AVFrameSideDataType frameType, enum AVPacketSideDataType packetType, size_t size) {
    const AVFrameSideData *side = av_frame_get_side_data(frame, frameType);
    if (side && side->size >= size) return side->data;
    const AVPacketSideData *packet = av_packet_side_data_get(params->coded_side_data,
        params->nb_coded_side_data, packetType);
    return packet && packet->size >= size ? packet->data : NULL;
}
static void attachData(CVPixelBufferRef pixel, CFStringRef key, const uint8_t *bytes, size_t size) {
    CFDataRef data = CFDataCreate(NULL, bytes, size);
    if (data) { CVBufferSetAttachment(pixel, key, data, kCVAttachmentMode_ShouldPropagate); CFRelease(data); }
}
static uint32_t scaled(AVRational value, double factor, double maximum) {
    double number = av_q2d(value) * factor;
    return isfinite(number) ? (uint32_t)llround(fmin(maximum, fmax(0, number))) : 0;
}
static void attachHDR(AVFrame *frame, const AVCodecParameters *params,
    CVPixelBufferRef pixel, CinevaFFmpegSnapshot *info) {
    const AVMasteringDisplayMetadata *mastering = (const void *)metadata(frame, params,
        AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, AV_PKT_DATA_MASTERING_DISPLAY_METADATA, sizeof(*mastering));
    if (mastering && mastering->has_primaries && mastering->has_luminance) {
        // CoreVideo uses the ISO mdcv payload: G, B, R; all integers big-endian.
        uint8_t data[24];
        const int order[] = {1, 2, 0};
        for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++)
            AV_WB16(data + i * 4 + j * 2, scaled(mastering->display_primaries[order[i]][j], 50000, 50000));
        AV_WB16(data + 12, scaled(mastering->white_point[0], 50000, 50000));
        AV_WB16(data + 14, scaled(mastering->white_point[1], 50000, 50000));
        AV_WB32(data + 16, scaled(mastering->max_luminance, 10000, UINT32_MAX));
        AV_WB32(data + 20, scaled(mastering->min_luminance, 10000, UINT32_MAX));
        attachData(pixel, kCVImageBufferMasteringDisplayColorVolumeKey, data, sizeof(data));
    }
    const AVContentLightMetadata *light = (const void *)metadata(frame, params,
        AV_FRAME_DATA_CONTENT_LIGHT_LEVEL, AV_PKT_DATA_CONTENT_LIGHT_LEVEL, sizeof(*light));
    if (light) {
        uint8_t data[4];
        AV_WB16(data, FFMIN(light->MaxCLL, UINT16_MAX));
        AV_WB16(data + 2, FFMIN(light->MaxFALL, UINT16_MAX));
        attachData(pixel, kCVImageBufferContentLightLevelInfoKey, data, sizeof(data));
    }
    info->hasMastering = CVBufferHasAttachment(pixel, kCVImageBufferMasteringDisplayColorVolumeKey);
    info->hasContentLight = CVBufferHasAttachment(pixel, kCVImageBufferContentLightLevelInfoKey);
}
int cineva_copy_video_surface(AVFrame *frame, const AVCodecParameters *params,
    struct SwsContext **scale, CVPixelBufferRef *output, CinevaFFmpegSnapshot *info) {
    *output = NULL;
    if (frame->width <= 0 || frame->height <= 0 ||
        (int64_t)frame->width * frame->height > 4096LL * 2304) return AVERROR(EFBIG);
    if (frame->color_primaries == AVCOL_PRI_UNSPECIFIED) frame->color_primaries = params->color_primaries;
    if (frame->color_trc == AVCOL_TRC_UNSPECIFIED) frame->color_trc = params->color_trc;
    if (frame->colorspace == AVCOL_SPC_UNSPECIFIED) frame->colorspace = params->color_space;
    if (frame->color_range == AVCOL_RANGE_UNSPECIFIED) frame->color_range = params->color_range;
    CVPixelBufferRef pixel = NULL;
    int hardware = frame->format == AV_PIX_FMT_VIDEOTOOLBOX;
    if (hardware) {
        // data[3] is the retained output surface, not CPU image bytes.
        pixel = (CVPixelBufferRef)frame->data[3];
        if (!pixel) return AVERROR_INVALIDDATA;
        CVPixelBufferRetain(pixel);
    } else {
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(frame->format);
        if (!desc) return AVERROR(ENOTSUP);
        int tenBit = desc->comp[0].depth > 8 || frame->color_trc == AVCOL_TRC_SMPTE2084 ||
            frame->color_trc == AVCOL_TRC_ARIB_STD_B67;
        int full = frame->color_range == AVCOL_RANGE_JPEG;
        OSType type = tenBit ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) :
            (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        enum AVPixelFormat format = tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        double ratio = fmin(1, fmin(1280.0 / frame->width, 720.0 / frame->height));
        int width = FFMAX(2, (int)(frame->width * ratio) & ~1);
        int height = FFMAX(2, (int)(frame->height * ratio) & ~1);
        CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *keys[] = { kCVPixelBufferIOSurfacePropertiesKey };
        const void *values[] = { empty };
        CFDictionaryRef attrs = empty ? CFDictionaryCreate(NULL, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
        if (!attrs) { if (empty) CFRelease(empty); return AVERROR(ENOMEM); }
        CVReturn result = CVPixelBufferCreate(NULL, width, height, type, attrs, &pixel);
        CFRelease(attrs); CFRelease(empty);
        if (result != kCVReturnSuccess) return AVERROR(ENOMEM);
        *scale = sws_getCachedContext(*scale, frame->width, frame->height, frame->format,
            width, height, format, SWS_BILINEAR, NULL, NULL, NULL);
        if (!*scale) { CVPixelBufferRelease(pixel); return AVERROR(ENOMEM); }
        // Preserve source YUV values/range/transfer; this is not an SDR tone map.
        int space = frame->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 :
            (frame->colorspace == AVCOL_SPC_BT709 || frame->height > 576 ? SWS_CS_ITU709 : SWS_CS_ITU601);
        const int *coefficients = sws_getCoefficients(space);
        sws_setColorspaceDetails(*scale, coefficients, full, coefficients, full, 0, 1 << 16, 1 << 16);
        if (CVPixelBufferLockBaseAddress(pixel, 0) != kCVReturnSuccess) {
            CVPixelBufferRelease(pixel); return AVERROR(EIO);
        }
        uint8_t *planes[] = { CVPixelBufferGetBaseAddressOfPlane(pixel, 0), CVPixelBufferGetBaseAddressOfPlane(pixel, 1), NULL, NULL };
        int strides[] = { (int)CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pixel, 1), 0, 0 };
        int rows = sws_scale(*scale, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        if (rows < 0) { CVPixelBufferRelease(pixel); return rows; }
    }
    // Preserve existing decoder attachments when AVFrame leaves a field unknown.
    if (!hardware) {
        int result = av_vt_pixbuf_set_attachments(NULL, pixel, frame);
        if (result < 0) { CVPixelBufferRelease(pixel); return result; }
    } else {
        CFStringRef primaries = av_map_videotoolbox_color_primaries_from_av(frame->color_primaries);
        CFStringRef transfer = av_map_videotoolbox_color_trc_from_av(frame->color_trc);
        CFStringRef matrix = av_map_videotoolbox_color_matrix_from_av(frame->colorspace);
        if (primaries) CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, primaries, kCVAttachmentMode_ShouldPropagate);
        if (transfer) CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
        if (matrix) CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    }
    OSType pixelType = CVPixelBufferGetPixelFormatType(pixel);
    enum AVPixelFormat mapped = av_map_videotoolbox_format_to_pixfmt(pixelType);
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(mapped);
    info->decoderType = hardware ? 2 : 1;
    info->outputWidth = (int)CVPixelBufferGetWidth(pixel);
    info->outputHeight = (int)CVPixelBufferGetHeight(pixel);
    info->outputBitDepth = desc ? desc->comp[0].depth : 0;
    info->colorPrimaries = frame->color_primaries;
    info->colorTransfer = frame->color_trc;
    info->colorMatrix = frame->colorspace;
    if ((frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67) && info->outputBitDepth < 10) {
        CVPixelBufferRelease(pixel); return AVERROR(ENOTSUP);
    }
    attachHDR(frame, params, pixel, info);
    *output = pixel;
    return 0;
}
