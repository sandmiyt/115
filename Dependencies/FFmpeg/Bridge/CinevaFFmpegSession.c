#include "CinevaFFmpeg.h"
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
    // Phase 3 is an SDR software validation surface, not an HDR tone mapper.
    if (frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67)
        return AVERROR(ENOTSUP);
    if (frame->width <= 0 || frame->height <= 0 ||
        (int64_t)frame->width * frame->height > 4096LL * 2304) return AVERROR(EFBIG);
    double ratio = fmin(1.0, fmin(1280.0 / frame->width, 720.0 / frame->height));
    int width = FFMAX(2, (int)(frame->width * ratio) & ~1);
    int height = FFMAX(2, (int)(frame->height * ratio) & ~1);
    CVPixelBufferRef pixel = NULL;
    const void *keys[] = { kCVPixelBufferIOSurfacePropertiesKey };
    CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *values[] = { empty };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CVReturn result = CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA, attrs, &pixel);
    CFRelease(attrs); CFRelease(empty);
    if (result != kCVReturnSuccess) return AVERROR(ENOMEM);
    s->scale = sws_getCachedContext(s->scale, frame->width, frame->height, frame->format,
        width, height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!s->scale) { CVPixelBufferRelease(pixel); return AVERROR(ENOMEM); }
    int colorspace = frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 :
        (frame->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 : SWS_CS_ITU601);
    const int *coefficients = sws_getCoefficients(colorspace);
    sws_setColorspaceDetails(s->scale, coefficients, frame->color_range == AVCOL_RANGE_JPEG,
        coefficients, 1, 0, 1 << 16, 1 << 16);
    CVPixelBufferLockBaseAddress(pixel, 0);
    uint8_t *planes[] = { CVPixelBufferGetBaseAddress(pixel), NULL, NULL, NULL };
    int strides[] = { (int)CVPixelBufferGetBytesPerRow(pixel), 0, 0, 0 };
    int rows = sws_scale(s->scale, (const uint8_t *const *)frame->data, frame->linesize,
        0, frame->height, planes, strides);
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    if (rows < 0) { CVPixelBufferRelease(pixel); return rows; }
    pthread_mutex_lock(&s->mutex);
    while (s->frameCount == FRAMES && !atomic_load(&s->cancelled) &&
           serial == atomic_load(&s->generation)) pthread_cond_wait(&s->changed, &s->mutex);
    if (atomic_load(&s->cancelled) || serial != atomic_load(&s->generation)) {
        CVPixelBufferRelease(pixel);
    } else {
        s->frames[(s->frameHead + s->frameCount++) % FRAMES] = (Frame){pixel, fmax(0, pts), serial};
        s->snapshot.videoFrames++;
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
        if (entry.eof) {
            result = decodePacket(s, s->video, frame, 1, entry, &nextPTS);
            if (result >= 0 && s->audio) result = decodePacket(s, s->audio, frame, 0, entry, &nextPTS);
            pthread_mutex_lock(&s->mutex);
            if (entry.serial == atomic_load(&s->generation) && result >= 0) s->snapshot.status = 2;
            pthread_mutex_unlock(&s->mutex);
        } else {
            int isVideo = entry.packet->stream_index == s->videoIndex;
            result = decodePacket(s, isVideo ? s->video : s->audio, frame, isVideo, entry, &nextPTS);
        }
        av_packet_free(&entry.packet);
        if (result < 0) { fail(s, result); break; }
    }
    av_frame_free(&frame);
    return NULL;
}
static int openDecoder(CinevaFFmpegSession *s, int index, AVCodecContext **context) {
    AVCodecParameters *params = s->format->streams[index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(params->codec_id);
    if (!codec) return AVERROR_DECODER_NOT_FOUND;
    *context = avcodec_alloc_context3(codec);
    if (!*context) return AVERROR(ENOMEM);
    int error = avcodec_parameters_to_context(*context, params);
    if (error < 0) return error;
    // Deliberately software only in Phase 3. Avoid unbounded auto-thread counts.
    (*context)->thread_count = 2;
    (*context)->pkt_timebase = s->format->streams[index]->time_base;
    (*context)->max_pixels = 4096LL * 2304;
    return avcodec_open2(*context, codec, NULL);
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
    result = openDecoder(s, s->videoIndex, &s->video);
    if (result < 0) goto done;
    if (s->audioIndex >= 0) {
        result = openDecoder(s, s->audioIndex, &s->audio);
        if (result < 0) goto done;
    }
    AVStream *video = s->format->streams[s->videoIndex];
    s->videoTimeBase = video->time_base;
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
            clearQueues(s); s->snapshot.status = 1;
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

CinevaFFmpegSession *CinevaFFmpegSessionCreate(const char *url, const char *headers, double startTime) {
    if (strncmp(url, "https://", 8) && strncmp(url, "http://", 7)) return NULL;
    CinevaFFmpegSession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    pthread_mutex_init(&s->mutex, NULL); pthread_cond_init(&s->changed, NULL);
    atomic_init(&s->cancelled, 0); atomic_init(&s->generation, 1);
    atomic_init(&s->interruptSeek, 0); atomic_init(&s->ioGeneration, 1);
    atomic_init(&s->deadline, 0);
    s->url = strdup(url); s->headers = strdup(headers);
    s->target = isfinite(startTime) ? fmax(0, startTime) : 0;
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
    avformat_close_input(&s->format);
    free(s->url); free(s->headers);
    pthread_cond_destroy(&s->changed); pthread_mutex_destroy(&s->mutex);
    free(s);
}
int CinevaFFmpegSessionSeek(CinevaFFmpegSession *s, double seconds) {
    pthread_mutex_lock(&s->mutex);
    s->target = isfinite(seconds) ? fmax(0, seconds) : 0;
    int serial = atomic_fetch_add(&s->generation, 1) + 1;
    if (s->snapshot.status > 0) s->snapshot.status = 1;
    clearQueues(s);
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
    return serial;
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
