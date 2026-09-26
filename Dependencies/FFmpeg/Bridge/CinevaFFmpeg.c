#include "CinevaFFmpeg.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

const char *CinevaFFmpegVersion(void) { return av_version_info(); }
const char *CinevaFFmpegConfiguration(void) { return avcodec_configuration(); }
const char *CinevaFFmpegLicense(void) { return avcodec_license(); }
int CinevaFFmpegHasDecoder(const char *name) {
    return avcodec_find_decoder_by_name(name) != NULL;
}
int CinevaFFmpegHasDemuxer(const char *name) {
    return av_find_input_format(name) != NULL;
}
int CinevaFFmpegHasVideoToolbox(const char *name) {
    const AVCodec *codec = avcodec_find_decoder_by_name(name);
    if (!codec) return 0;
    for (int i = 0;; i++) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
        if (!config) return 0;
        if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) return 1;
    }
}
int CinevaFFmpegRuntimeCheck(void) {
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *codec = avcodec_alloc_context3(avcodec_find_decoder_by_name("h264"));
    AVFrame *frame = av_frame_alloc();
    SwrContext *resample = swr_alloc();
    struct SwsContext *scale = sws_getContext(16, 16, AV_PIX_FMT_YUV420P,
        16, 16, AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
    int ok = format && codec && frame && resample && scale;
    sws_freeContext(scale);
    swr_free(&resample);
    av_frame_free(&frame);
    avcodec_free_context(&codec);
    avformat_free_context(format);
    return ok;
}
