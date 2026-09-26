#include "CinevaFFmpeg.h"
#include "CinevaVideoOutput.h"
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <VideoToolbox/VideoToolbox.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define PACKETS 256
#define FRAMES 6
#define BYTE_LIMIT (16 * 1024 * 1024)
typedef struct { AVPacket *packet; int serial, eof; double duration, target; } Packet;
typedef struct { CVPixelBufferRef buffer; double pts; int serial; } Frame;
struct CinevaFFmpegSession {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    pthread_t reader, decoder;
    int hasReader, hasDecoder;
    atomic_int cancelled, generation, interruptSeek, ioGeneration;
    atomic_llong deadline;
    char *url, *headers;
    double target, origin;
    AVFormatContext *format;
    AVCodecContext *video, *audio;
    AVCodecParameters *videoParameters;
    int disableHardware, hardwareAttempted;
    double playbackPosition;
    int videoIndex, audioIndex;
    AVRational videoTimeBase;
    struct SwsContext *scale;
    Packet packets[PACKETS];
    int packetHead, packetCount;
    int64_t packetBytes;
    double packetSeconds;
    Frame frames[FRAMES];
    int frameHead, frameCount;
    CinevaFFmpegSnapshot snapshot;
};

static int interrupted(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    return atomic_load(&s->cancelled) ||
        (atomic_load(&s->deadline) > 0 && av_gettime_relative() > atomic_load(&s->deadline)) ||
        (atomic_load(&s->interruptSeek) &&
         atomic_load(&s->ioGeneration) != atomic_load(&s->generation));
}
static void fail(CinevaFFmpegSession *s, int error) {
    pthread_mutex_lock(&s->mutex);
    s->snapshot.status = -1;
    s->snapshot.errorCode = error;
    atomic_store(&s->cancelled, 1);
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->mutex);
}
static void clearQueues(CinevaFFmpegSession *s) {
    for (int i = 0; i < s->packetCount; i++) {
        Packet *p = &s->packets[(s->packetHead + i) % PACKETS];
        av_packet_free(&p->packet);
    }
    for (int i = 0; i < s->frameCount; i++)
        CVPixelBufferRelease(s->frames[(s->frameHead + i) % FRAMES].buffer);
    s->packetCount = s->packetHead = s->frameCount = s->frameHead = 0;
    s->packetBytes = 0; s->packetSeconds = 0;
}
static int putPacket(CinevaFFmpegSession *s, Packet entry) {
    pthread_mutex_lock(&s->mutex);
    int bytes = entry.packet ? entry.packet->size : 0;
    while (!atomic_load(&s->cancelled) && entry.serial == atomic_load(&s->generation) &&
           (s->packetCount >= PACKETS || s->packetBytes + bytes > BYTE_LIMIT ||
            (s->packetCount > 0 && s->packetSeconds >= 4.0)))
        pthread_cond_wait(&s->changed, &s->mutex);
    int ok = !atomic_load(&s->cancelled) && entry.serial == atomic_load(&s->generation);
    if (ok) {
        s->packets[(s->packetHead + s->packetCount++) % PACKETS] = entry;
        s->packetBytes += bytes; s->packetSeconds += entry.duration;
    }
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->mutex);
    if (!ok) av_packet_free(&entry.packet);
    return ok;
}

static int emitVideo(CinevaFFmpegSession *s, AVFrame *frame, int serial, double target,
                     double *nextPTS) {
    double pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? *nextPTS :
        frame->best_effort_timestamp * av_q2d(s->videoTimeBase) - s->origin;
    if (!isfinite(pts)) pts = *nextPTS;
    double step = frame->duration > 0 ? frame->duration * av_q2d(s->videoTimeBase) :
        1.0 / (s->snapshot.fps > 0 ? s->snapshot.fps : 30);
    *nextPTS = pts + step;
    if (pts + 0.001 < target || serial != atomic_load(&s->generation)) return 0;
    CVPixelBufferRef pixel = NULL;
    CinevaFFmpegSnapshot output = {0};
    int error = cineva_copy_video_surface(frame, s->videoParameters, &s->scale, &pixel, &output);
    if (error < 0) return error;
    pthread_mutex_lock(&s->mutex);
    int frameLimit = output.outputWidth * output.outputHeight > 1920 * 1080 ? 3 : FRAMES;
    while (s->frameCount >= frameLimit && !atomic_load(&s->cancelled) &&
           serial == atomic_load(&s->generation)) pthread_cond_wait(&s->changed, &s->mutex);
    if (atomic_load(&s->cancelled) || serial != atomic_load(&s->generation)) {
        CVPixelBufferRelease(pixel);
    } else {
        s->frames[(s->frameHead + s->frameCount++) % FRAMES] = (Frame){pixel, fmax(0, pts), serial};
        s->snapshot.videoFrames++;
        s->snapshot.decoderType = output.decoderType;
        s->snapshot.hardwareFrames += output.decoderType == 2;
        s->snapshot.softwareFrames += output.decoderType == 1;
        s->snapshot.outputWidth = output.outputWidth; s->snapshot.outputHeight = output.outputHeight;
        s->snapshot.outputBitDepth = output.outputBitDepth;
        s->snapshot.colorPrimaries = output.colorPrimaries; s->snapshot.colorTransfer = output.colorTransfer;
        s->snapshot.colorMatrix = output.colorMatrix;
        s->snapshot.hasMastering = output.hasMastering; s->snapshot.hasContentLight = output.hasContentLight;
    }
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->mutex);
    return 0;
}

static int receiveFrames(CinevaFFmpegSession *s, AVCodecContext *codec, AVFrame *frame,
                         int video, Packet entry, double *nextPTS) {
    int result;
    while ((result = avcodec_receive_frame(codec, frame)) >= 0) {
        if (atomic_load(&s->cancelled) || entry.serial != atomic_load(&s->generation)) {
            av_frame_unref(frame); return 0;
        }
        int error = 0;
        if (video) error = emitVideo(s, frame, entry.serial, entry.target, nextPTS);
        else {
            pthread_mutex_lock(&s->mutex);
            s->snapshot.audioFrames++;
            pthread_mutex_unlock(&s->mutex);
        }
        av_frame_unref(frame);
        if (error < 0) return error;
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}
static int decodePacket(CinevaFFmpegSession *s, AVCodecContext *codec, AVFrame *frame,
                        int video, Packet entry, double *nextPTS) {
    int result = avcodec_send_packet(codec, entry.packet);
    if (result == AVERROR(EAGAIN)) {
        result = receiveFrames(s, codec, frame, video, entry, nextPTS);
        if (result >= 0) result = avcodec_send_packet(codec, entry.packet);
    }
    if (result < 0 && result != AVERROR_EOF) return result;
    return receiveFrames(s, codec, frame, video, entry, nextPTS);
}
static int openVideoDecoder(CinevaFFmpegSession *s);
static int recoverSoftware(CinevaFFmpegSession *s, Packet entry) {
    if (s->disableHardware || !s->hardwareAttempted) return 0;
    s->disableHardware = 1;
    avcodec_free_context(&s->video);
    int result = openVideoDecoder(s);
    if (result < 0) return result;
    pthread_mutex_lock(&s->mutex);
    s->snapshot.fallbackReason = 4;
    if (entry.serial == atomic_load(&s->generation)) {
        s->target = fmax(entry.target, s->playbackPosition);
    }
    // A user seek may have raced codec reconstruction. Keep its latest target,
    // but always restart the demuxer so we never discard its new keyframe only.
    s->snapshot.recoveryTarget = s->target;
    atomic_fetch_add(&s->generation, 1);
    clearQueues(s);
    s->snapshot.status = 1;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->mutex);
    return 1;
}
static void *decodeLoop(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    AVFrame *frame = av_frame_alloc();
    if (!frame) { fail(s, AVERROR(ENOMEM)); return NULL; }
    int serial = -1;
    double nextPTS = 0;
    while (!atomic_load(&s->cancelled)) {
        pthread_mutex_lock(&s->mutex);
        while (!s->packetCount && !atomic_load(&s->cancelled))
            pthread_cond_wait(&s->changed, &s->mutex);
        if (atomic_load(&s->cancelled)) { pthread_mutex_unlock(&s->mutex); break; }
        Packet entry = s->packets[s->packetHead];
        s->packetHead = (s->packetHead + 1) % PACKETS; s->packetCount--;
        s->packetBytes -= entry.packet ? entry.packet->size : 0;
        s->packetSeconds = fmax(0, s->packetSeconds - entry.duration);
        pthread_cond_broadcast(&s->changed);
        pthread_mutex_unlock(&s->mutex);
        if (entry.serial != atomic_load(&s->generation)) { av_packet_free(&entry.packet); continue; }
        if (serial != entry.serial) {
            avcodec_flush_buffers(s->video);
            if (s->audio) avcodec_flush_buffers(s->audio);
            serial = entry.serial; nextPTS = entry.target;
        }
        int result;
        int videoOperation = entry.eof || entry.packet->stream_index == s->videoIndex;
        if (entry.eof) {
            result = decodePacket(s, s->video, frame, 1, entry, &nextPTS);
            if (result >= 0 && s->audio) {
                videoOperation = 0;
                result = decodePacket(s, s->audio, frame, 0, entry, &nextPTS);
            }
            pthread_mutex_lock(&s->mutex);
            if (entry.serial == atomic_load(&s->generation) && result >= 0 &&
                !atomic_load(&s->cancelled)) s->snapshot.status = 2;
            pthread_mutex_unlock(&s->mutex);
        } else {
            int isVideo = entry.packet->stream_index == s->videoIndex;
            result = decodePacket(s, isVideo ? s->video : s->audio, frame, isVideo, entry, &nextPTS);
        }
        if (result < 0 && videoOperation && entry.serial == atomic_load(&s->generation) &&
            !atomic_load(&s->cancelled)) {
            int recovered = recoverSoftware(s, entry);
            if (recovered > 0) { av_packet_free(&entry.packet); continue; }
            if (recovered < 0) result = recovered;
        }
        av_packet_free(&entry.packet);
        if (result < 0 && entry.serial == atomic_load(&s->generation)) { fail(s, result); break; }
    }
    av_frame_free(&frame);
    return NULL;
}
static void setFallback(CinevaFFmpegSession *s, int reason) {
    pthread_mutex_lock(&s->mutex);
    if (!s->snapshot.fallbackReason) s->snapshot.fallbackReason = reason;
    pthread_mutex_unlock(&s->mutex);
}
static enum AVPixelFormat chooseVideoFormat(AVCodecContext *codec, const enum AVPixelFormat *formats) {
    CinevaFFmpegSession *s = codec->opaque;
    if (!s->disableHardware && codec->hw_device_ctx) {
        for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) { s->hardwareAttempted = 1; return *p; }
        // FFmpeg calls get_format again without VT when its session rejects the
        // current profile/pixel format. Choose an actual software format then.
        s->disableHardware = 1;
        setFallback(s, 3);
    }
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(*p);
        if (desc && !(desc->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return AV_PIX_FMT_NONE;
}
static CMVideoCodecType appleCodec(enum AVCodecID codec) {
    switch (codec) {
        case AV_CODEC_ID_H264: return kCMVideoCodecType_H264;
        case AV_CODEC_ID_HEVC: return kCMVideoCodecType_HEVC;
        case AV_CODEC_ID_VP9: return kCMVideoCodecType_VP9;
        case AV_CODEC_ID_AV1: return kCMVideoCodecType_AV1;
        case AV_CODEC_ID_MPEG2VIDEO: return kCMVideoCodecType_MPEG2Video;
        case AV_CODEC_ID_MPEG4: return kCMVideoCodecType_MPEG4Video;
        default: return 0;
    }
}
static int allocateDecoder(const AVCodecParameters *params, AVRational timebase, AVCodecContext **context) {
    const AVCodec *codec = avcodec_find_decoder(params->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    *context = avcodec_alloc_context3(codec);
    if (!*context) return AVERROR(ENOMEM);
    int error = avcodec_parameters_to_context(*context, params);
    if (error < 0) return error;
    (*context)->thread_count = 2;
    (*context)->pkt_timebase = timebase;
    (*context)->max_pixels = 4096LL * 2304;
    return 0;
}
static int openVideoDecoder(CinevaFFmpegSession *s) {
    int result = allocateDecoder(s->videoParameters, s->videoTimeBase, &s->video);
    if (result < 0) return result;
    s->video->opaque = s;
    s->video->get_format = chooseVideoFormat;
    s->video->thread_type = FF_THREAD_SLICE;
    if (!s->disableHardware) {
        CMVideoCodecType type = appleCodec(s->video->codec_id);
        int hasConfig = 0;
        for (int i = 0;; i++) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(s->video->codec, i);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) { hasConfig = 1; break; }
        }
        if (type && hasConfig && VTIsHardwareDecodeSupported(type)) {
            result = av_hwdevice_ctx_create(&s->video->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
            if (result < 0) { s->disableHardware = 1; setFallback(s, 2); }
        } else { s->disableHardware = 1; setFallback(s, 1); }
    }
    result = avcodec_open2(s->video, s->video->codec, NULL);
    if (result < 0 && !s->disableHardware) {
        s->disableHardware = 1; setFallback(s, 3);
        avcodec_free_context(&s->video);
        return openVideoDecoder(s);
    }
    return result;
}
static void *readLoop(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    AVDictionary *options = NULL;
    int result = 0;
    // Keep signed URLs, cookies and credentials out of FFmpeg's process log.
    av_log_set_level(AV_LOG_QUIET);
    s->format = avformat_alloc_context();
    if (!s->format) { fail(s, AVERROR(ENOMEM)); return NULL; }
    s->format->interrupt_callback = (AVIOInterruptCB){ interrupted, s };
    av_dict_set(&options, "headers", s->headers, 0);
    av_dict_set(&options, "rw_timeout", "10000000", 0);
    av_dict_set(&options, "protocol_whitelist", "http,https,tcp,tls,crypto", 0);
    av_dict_set(&options, "probesize", "2097152", 0);
    av_dict_set(&options, "analyzeduration", "3000000", 0);
    atomic_store(&s->deadline, av_gettime_relative() + 30000000);
    result = avformat_open_input(&s->format, s->url, NULL, &options);
    av_dict_free(&options);
    if (result < 0) goto done;
    result = avformat_find_stream_info(s->format, NULL);
    if (result < 0) goto done;
    s->videoIndex = av_find_best_stream(s->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (s->videoIndex < 0) { result = s->videoIndex; goto done; }
    s->audioIndex = av_find_best_stream(s->format, AVMEDIA_TYPE_AUDIO, -1, s->videoIndex, NULL, 0);
    AVStream *video = s->format->streams[s->videoIndex];
    s->videoTimeBase = video->time_base;
    s->videoParameters = avcodec_parameters_alloc();
    if (!s->videoParameters) { result = AVERROR(ENOMEM); goto done; }
    result = avcodec_parameters_copy(s->videoParameters, video->codecpar);
    if (result < 0) goto done;
    // Dolby's per-frame pipeline is a later phase; preserve the existing native path.
    if (av_packet_side_data_get(s->videoParameters->coded_side_data,
        s->videoParameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)) {
        result = -70001; goto done;
    }
    result = openVideoDecoder(s);
    if (result < 0) goto done;
    if (s->audioIndex >= 0) {
        AVStream *audio = s->format->streams[s->audioIndex];
        result = allocateDecoder(audio->codecpar, audio->time_base, &s->audio);
        if (result < 0) goto done;
        result = avcodec_open2(s->audio, s->audio->codec, NULL);
        if (result < 0) goto done;
    }
    s->origin = s->format->start_time != AV_NOPTS_VALUE ? (double)s->format->start_time / AV_TIME_BASE :
        (video->start_time != AV_NOPTS_VALUE ? video->start_time * av_q2d(video->time_base) : 0);
    const AVPacketSideData *matrix = av_packet_side_data_get(video->codecpar->coded_side_data,
        video->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    pthread_mutex_lock(&s->mutex);
    s->snapshot.width = s->video->width; s->snapshot.height = s->video->height;
    s->snapshot.videoCodec = s->video->codec_id;
    s->snapshot.audioCodec = s->audio ? s->audio->codec_id : AV_CODEC_ID_NONE;
    s->snapshot.fps = av_q2d(av_guess_frame_rate(s->format, video, NULL));
    s->snapshot.duration = s->format->duration > 0 ? (double)s->format->duration / AV_TIME_BASE : 0;
    s->snapshot.rotation = matrix && matrix->size >= 9 * sizeof(int32_t) ?
        -av_display_rotation_get((const int32_t *)matrix->data) : 0;
    s->snapshot.status = 1;
    pthread_mutex_unlock(&s->mutex);
    if (pthread_create(&s->decoder, NULL, decodeLoop, s)) { result = AVERROR(ENOMEM); goto done; }
    s->hasDecoder = 1;
    int serial = -1, eof = 0;
    double target = 0;
    while (!atomic_load(&s->cancelled)) {
        int wanted = atomic_load(&s->generation);
        if (wanted != serial) {
            pthread_mutex_lock(&s->mutex);
            target = s->target;
            clearQueues(s);
            if (!atomic_load(&s->cancelled)) s->snapshot.status = 1;
            pthread_cond_broadcast(&s->changed);
            pthread_mutex_unlock(&s->mutex);
            atomic_store(&s->interruptSeek, 0);
            if (serial >= 0 || target > 0) {
                if (s->format->pb) { s->format->pb->error = 0; s->format->pb->eof_reached = 0; }
                int64_t stamp = (int64_t)((target + s->origin) * AV_TIME_BASE);
                atomic_store(&s->deadline, av_gettime_relative() + 10000000);
                result = avformat_seek_file(s->format, -1, INT64_MIN, stamp, stamp, AVSEEK_FLAG_BACKWARD);
                if (result < 0) goto done;
                avformat_flush(s->format);
            }
            serial = wanted; eof = 0;
            continue;
        }
        if (eof) {
            pthread_mutex_lock(&s->mutex);
            while (!atomic_load(&s->cancelled) && serial == atomic_load(&s->generation))
                pthread_cond_wait(&s->changed, &s->mutex);
            pthread_mutex_unlock(&s->mutex);
            continue;
        }
        AVPacket *packet = av_packet_alloc();
        if (!packet) { result = AVERROR(ENOMEM); goto done; }
        atomic_store(&s->ioGeneration, serial); atomic_store(&s->interruptSeek, 1);
        atomic_store(&s->deadline, av_gettime_relative() + 10000000);
        result = av_read_frame(s->format, packet);
        atomic_store(&s->interruptSeek, 0);
        if (serial != atomic_load(&s->generation)) { av_packet_free(&packet); continue; }
        if (result == AVERROR_EOF) {
            av_packet_free(&packet);
            putPacket(s, (Packet){NULL, serial, 1, 0, target}); eof = 1; continue;
        }
        if (result < 0) { av_packet_free(&packet); goto done; }
        if (packet->stream_index != s->videoIndex && packet->stream_index != s->audioIndex) {
            av_packet_free(&packet); continue;
        }
        if (packet->size > BYTE_LIMIT) { av_packet_free(&packet); result = AVERROR(EFBIG); goto done; }
        double seconds = packet->duration > 0 ? packet->duration *
            av_q2d(s->format->streams[packet->stream_index]->time_base) : 0;
        putPacket(s, (Packet){packet, serial, 0, fmin(seconds, 4.0), target});
    }
done:
    if (result < 0 && !atomic_load(&s->cancelled)) fail(s, result);
    if (s->hasDecoder) pthread_join(s->decoder, NULL);
    return NULL;
}

CinevaFFmpegSession *CinevaFFmpegSessionCreate(const char *url, const char *headers, double startTime, int preferHardware) {
    if (strncmp(url, "https://", 8) && strncmp(url, "http://", 7)) return NULL;
    CinevaFFmpegSession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    pthread_mutex_init(&s->mutex, NULL); pthread_cond_init(&s->changed, NULL);
    atomic_init(&s->cancelled, 0); atomic_init(&s->generation, 1);
    atomic_init(&s->interruptSeek, 0); atomic_init(&s->ioGeneration, 1);
    atomic_init(&s->deadline, 0);
    s->url = strdup(url); s->headers = strdup(headers);
    s->target = isfinite(startTime) ? fmax(0, startTime) : 0;
    s->playbackPosition = s->target;
    s->snapshot.recoveryTarget = s->target;
    s->disableHardware = !preferHardware;
    s->snapshot.fallbackReason = preferHardware ? 0 : 5;
    if (!s->url || !s->headers || pthread_create(&s->reader, NULL, readLoop, s)) {
        CinevaFFmpegSessionDestroy(s); return NULL;
    }
    s->hasReader = 1;
    return s;
}
void CinevaFFmpegSessionCancel(CinevaFFmpegSession *s) {
    atomic_store(&s->cancelled, 1);
    pthread_mutex_lock(&s->mutex); pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
}
void CinevaFFmpegSessionDestroy(CinevaFFmpegSession *s) {
    CinevaFFmpegSessionCancel(s);
    if (s->hasReader) pthread_join(s->reader, NULL);
    clearQueues(s);
    sws_freeContext(s->scale);
    avcodec_free_context(&s->video); avcodec_free_context(&s->audio);
    avcodec_parameters_free(&s->videoParameters);
    avformat_close_input(&s->format);
    free(s->url); free(s->headers);
    pthread_cond_destroy(&s->changed); pthread_mutex_destroy(&s->mutex);
    free(s);
}
int CinevaFFmpegSessionSeek(CinevaFFmpegSession *s, double seconds) {
    pthread_mutex_lock(&s->mutex);
    s->target = isfinite(seconds) ? fmax(0, seconds) : 0;
    s->playbackPosition = s->target;
    s->snapshot.recoveryTarget = s->target;
    int serial = atomic_fetch_add(&s->generation, 1) + 1;
    if (s->snapshot.status > 0) s->snapshot.status = 1;
    clearQueues(s);
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
    return serial;
}
void CinevaFFmpegSessionSetPosition(CinevaFFmpegSession *s, double seconds) {
    if (!isfinite(seconds)) return;
    pthread_mutex_lock(&s->mutex);
    s->playbackPosition = fmax(0, seconds);
    pthread_mutex_unlock(&s->mutex);
}
void CinevaFFmpegSessionSnapshot(CinevaFFmpegSession *s, CinevaFFmpegSnapshot *snapshot) {
    pthread_mutex_lock(&s->mutex);
    *snapshot = s->snapshot;
    snapshot->serial = atomic_load(&s->generation);
    snapshot->packetBytes = s->packetBytes; snapshot->packetCount = s->packetCount;
    snapshot->frameCount = s->frameCount; snapshot->queuedSeconds = s->packetSeconds;
    pthread_mutex_unlock(&s->mutex);
}
CVPixelBufferRef CinevaFFmpegSessionCopyFrame(CinevaFFmpegSession *s, double *pts, int *serial) {
    pthread_mutex_lock(&s->mutex);
    CVPixelBufferRef result = NULL;
    if (s->frameCount) {
        Frame frame = s->frames[s->frameHead]; s->frameHead = (s->frameHead + 1) % FRAMES;
        s->frameCount--; *pts = frame.pts; *serial = frame.serial; result = frame.buffer;
    }
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
    return result;
}
const char *CinevaFFmpegCodecName(int codec) { return avcodec_get_name(codec); }
