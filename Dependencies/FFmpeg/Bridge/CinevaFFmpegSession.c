#include "CinevaFFmpeg.h"
#include "CinevaVideoOutput.h"
#include "CinevaSubtitles.h"
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <VideoToolbox/VideoToolbox.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>
#include <libavutil/bprint.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define PACKETS 512
#define FRAMES 6
#define BYTE_LIMIT (16 * 1024 * 1024)
typedef struct { AVPacket *packet; int serial, eof; double duration, target; } Packet;
typedef struct { CVPixelBufferRef buffer; double pts, duration; int serial; } Frame;
typedef struct { float *samples; double pts; int count, serial; } PCM;
#define PCM_LIMIT 96
struct CinevaFFmpegSession {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    pthread_t reader, decoder;
    pthread_t audioWorker;
    int hasAudioWorker;
    int hasReader, hasDecoder;
    atomic_int cancelled, generation, interruptSeek, ioGeneration;
    atomic_int wantedAudioIndex;
    atomic_int videoSuppressed;
    atomic_llong deadline;
    char *url, *headers;
    double target, origin;
    AVFormatContext *format;
    AVIOContext *customIO;
    int64_t customOffset;
    CinevaFFmpegSessionOptions options;
    AVCodecContext *video, *audio;
    AVCodecParameters *videoParameters;
    int disableHardware, hardwareAttempted;
    double playbackPosition;
    int64_t ioStartedUs, lastPacketUs, previousPacketEnd;
    int videoIndex, audioIndex, audioSourceIndex, videoOnly;
    AVRational videoTimeBase;
    struct SwsContext *scale;
    Packet packets[PACKETS];
    int packetHead, packetCount;
    int64_t packetBytes;
    double packetSeconds;
    Packet audioPackets[PACKETS];
    int audioHead, audioCount;
    int64_t audioBytes;
    double audioSeconds;
    PCM pcm[PCM_LIMIT];
    int pcmHead, pcmCount;
    double pcmSeconds, nextAudioPTS;
    SwrContext *resampler;
    AVChannelLayout inputLayout;
    int inputRate, inputFormat;
    AVRational audioTimeBase;
    CinevaFFmpegAudioTrack audioTracks[32];
    AVCodecParameters *audioParameters[32];
    AVRational audioBases[32];
    int trackCount;
    Frame frames[FRAMES];
    int frameHead, frameCount;
    double frameSeconds;
    CinevaFFmpegSnapshot snapshot;
    CinevaSubtitles *subtitles;
};

static int interrupted(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    return atomic_load(&s->cancelled) ||
        (atomic_load(&s->deadline) > 0 && av_gettime_relative() > atomic_load(&s->deadline)) ||
        (atomic_load(&s->interruptSeek) &&
         atomic_load(&s->ioGeneration) != atomic_load(&s->generation));
}
static int customRead(void *opaque, uint8_t *buffer, int capacity) {
    CinevaFFmpegSession *s = opaque;
    if (interrupted(s)) return AVERROR_EXIT;
    int n = s->options.read(s->options.ioContext, s->customOffset, buffer, capacity, atomic_load(&s->ioGeneration));
    if (n > 0) { s->customOffset += n; return n; }
    if (n == 0) return AVERROR_EOF;
    if (n == -3) return AVERROR_EXIT;
    if (n == -2) return AVERROR(ETIMEDOUT);
    return AVERROR(EIO);
}
static int64_t customSeek(void *opaque, int64_t offset, int whence) {
    CinevaFFmpegSession *s = opaque;
    int64_t size = s->options.size(s->options.ioContext);
    if (whence == AVSEEK_SIZE) return size >= 0 ? size : AVERROR(ENOSYS);
    whence &= ~AVSEEK_FORCE;
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? s->customOffset : whence == SEEK_END ? size : -1;
    if (base < 0 || (offset > 0 && base > INT64_MAX - offset) ||
        (offset < 0 && offset < -base)) return AVERROR(EINVAL);
    s->customOffset = base + offset;
    return s->customOffset; // Byte-level track switching never cancels cache windows.
}
static void closeInput(CinevaFFmpegSession *s) {
    avformat_close_input(&s->format);
    if (s->customIO) { av_freep(&s->customIO->buffer); avio_context_free(&s->customIO); }
}
static void fail(CinevaFFmpegSession *s, int error, int stage) {
    pthread_mutex_lock(&s->mutex);
    if (!atomic_load(&s->cancelled)) {
        s->snapshot.status = -1;
        s->snapshot.errorCode = error;
        s->snapshot.failureStage = stage;
    }
    atomic_store(&s->cancelled, 1);
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->mutex);
}
static void readerStage(CinevaFFmpegSession *s, int stage) {
    pthread_mutex_lock(&s->mutex);
    s->snapshot.readerStage = stage;
    s->ioStartedUs = stage == CinevaStageOpen || stage == CinevaStageProbe ||
        stage == CinevaStageSeek || stage == CinevaStageRead ? av_gettime_relative() : 0;
    pthread_mutex_unlock(&s->mutex);
}
// Only the reader touches AVIOContext. The UI reads our locked copy, never
// concurrently reads libavformat's mutable counters or calls avio_size/seek.
static void readerFinished(CinevaFFmpegSession *s, int packetRead) {
    pthread_mutex_lock(&s->mutex);
    if (packetRead && s->ioStartedUs) {
        s->snapshot.lastReadSeconds = (av_gettime_relative() - s->ioStartedUs) / 1000000.0;
        s->snapshot.packetReadCount++;
        s->snapshot.averageReadFrameDuration += (s->snapshot.lastReadSeconds -
            s->snapshot.averageReadFrameDuration) / s->snapshot.packetReadCount;
        s->snapshot.maximumReadFrameDuration = fmax(s->snapshot.maximumReadFrameDuration, s->snapshot.lastReadSeconds);
    }
    s->ioStartedUs = 0;
    if (s->format && s->format->pb) {
        s->snapshot.ioBytesRead = s->format->pb->bytes_read;
        s->snapshot.ioPosition = avio_tell(s->format->pb);
    }
    pthread_mutex_unlock(&s->mutex);
}
static void decoderStage(CinevaFFmpegSession *s, int stage) {
    pthread_mutex_lock(&s->mutex);
    s->snapshot.decoderStage = stage;
    pthread_mutex_unlock(&s->mutex);
}
// Phase 3-5 audio only counts decoded frames. An unsupported/damaged audio
// track must not kill video validation. The later audio phase needs its own
// explicit output/track recovery policy rather than silently using this one.
static void disableValidationAudio(CinevaFFmpegSession *s, int error) {
    avcodec_free_context(&s->audio);
    pthread_mutex_lock(&s->mutex);
    s->snapshot.audioWarningCode = error;
    pthread_mutex_unlock(&s->mutex);
}
static void clearQueues(CinevaFFmpegSession *s) {
    for (int i = 0; i < s->audioCount; i++) av_packet_free(&s->audioPackets[(s->audioHead+i)%PACKETS].packet);
    for (int i = 0; i < s->pcmCount; i++) av_free(s->pcm[(s->pcmHead+i)%PCM_LIMIT].samples);
    s->audioCount = s->audioHead = s->pcmCount = s->pcmHead = 0;
    s->audioBytes = 0; s->audioSeconds = s->pcmSeconds = 0;
    s->snapshot.audioDrained = s->snapshot.videoDrained = 0;
    for (int i = 0; i < s->packetCount; i++) {
        Packet *p = &s->packets[(s->packetHead + i) % PACKETS];
        av_packet_free(&p->packet);
    }
    for (int i = 0; i < s->frameCount; i++)
        CVPixelBufferRelease(s->frames[(s->frameHead + i) % FRAMES].buffer);
    s->packetCount = s->packetHead = s->frameCount = s->frameHead = 0;
    s->packetBytes = 0; s->packetSeconds = 0;
    s->frameSeconds = 0;
    s->snapshot.demuxEOF = 0;
}
static int putPacket(CinevaFFmpegSession *s, Packet entry) {
    pthread_mutex_lock(&s->mutex);
    int bytes = entry.packet ? entry.packet->size : 0;
    int64_t blockedAt=av_gettime_relative();
    if (entry.packet && entry.packet->stream_index == s->audioIndex) {
        while (!atomic_load(&s->cancelled) && entry.serial == atomic_load(&s->generation) &&
            (s->audioCount >= PACKETS || s->audioBytes + bytes > 4*1024*1024 || s->audioSeconds >= 8))
        {
            s->snapshot.readerBackpressured=1;
            if (!atomic_load(&s->videoSuppressed) && !s->packetCount && !s->frameCount && av_gettime_relative()-blockedAt>8000000) {
                pthread_mutex_unlock(&s->mutex); av_packet_free(&entry.packet);
                fail(s,AVERROR(ENOBUFS),CinevaStageRead); return 0;
            }
            struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); ts.tv_sec++;
            pthread_cond_timedwait(&s->changed,&s->mutex,&ts);
        }
        s->snapshot.readerBackpressured=0;
        int ok = !atomic_load(&s->cancelled) && entry.serial == atomic_load(&s->generation);
        if (ok) {
            s->audioPackets[(s->audioHead+s->audioCount++)%PACKETS] = entry;
            s->audioBytes += bytes; s->audioSeconds += entry.duration;
        }
        pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
        if (!ok) av_packet_free(&entry.packet);
        return ok;
    }
    while (!atomic_load(&s->cancelled) && entry.serial == atomic_load(&s->generation) &&
           (s->packetCount >= PACKETS || s->packetBytes + bytes > BYTE_LIMIT ||
            (s->packetCount > 0 && s->packetSeconds >= 8.0))) {
        s->snapshot.readerBackpressured = 1;
        if (s->options.outputAudio && s->hasAudioWorker && !s->audioCount && !s->pcmCount && av_gettime_relative()-blockedAt>8000000) {
            pthread_mutex_unlock(&s->mutex); av_packet_free(&entry.packet);
            fail(s,AVERROR(ENOBUFS),CinevaStageRead); return 0;
        }
        struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); ts.tv_sec++;
        pthread_cond_timedwait(&s->changed,&s->mutex,&ts);
    }
    s->snapshot.readerBackpressured = 0;
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

static int putPCM(CinevaFFmpegSession *s, float *samples, int count, double pts, int serial, double target) {
    int trim = (int)fmin(count, ceil(fmax(0, target-pts)*48000));
    if (trim) { count -= trim; pts += trim/48000.0; memmove(samples, samples+trim*2, count*2*sizeof(float)); }
    if (!count) { av_free(samples); return 0; }
    pthread_mutex_lock(&s->mutex);
    while (!atomic_load(&s->cancelled) && serial == atomic_load(&s->generation) &&
        (s->pcmCount >= PCM_LIMIT || s->pcmSeconds >= 2.0)) pthread_cond_wait(&s->changed, &s->mutex);
    if (!atomic_load(&s->cancelled) && serial == atomic_load(&s->generation)) {
        s->pcm[(s->pcmHead+s->pcmCount++)%PCM_LIMIT] = (PCM){samples,pts,count,serial};
        s->pcmSeconds += count/48000.0;
        s->snapshot.audioDecodedTime = pts+count/48000.0;
        s->snapshot.audioCodec=s->audio->codec_id;
        s->snapshot.audioProfile=s->audio->profile;
        s->snapshot.atmosMetadataDetected=
            (s->audio->codec_id==AV_CODEC_ID_EAC3 && s->audio->profile==AV_PROFILE_EAC3_DDP_ATMOS) ||
            (s->audio->codec_id==AV_CODEC_ID_TRUEHD && s->audio->profile==AV_PROFILE_TRUEHD_ATMOS);
    } else av_free(samples);
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
    return 0;
}
static int emitAudio(CinevaFFmpegSession *s, AVFrame *frame, Packet entry) {
    if (!s->options.outputAudio) return 0;
    if (frame && (!s->resampler || s->inputRate != frame->sample_rate || s->inputFormat != frame->format ||
        av_channel_layout_compare(&s->inputLayout, &frame->ch_layout))) {
        swr_free(&s->resampler); av_channel_layout_uninit(&s->inputLayout);
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        int error = swr_alloc_set_opts2(&s->resampler, &stereo, AV_SAMPLE_FMT_FLT, 48000,
            &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
        if (error < 0 || (error = swr_init(s->resampler)) < 0) return error;
        av_channel_layout_copy(&s->inputLayout, &frame->ch_layout);
        s->inputRate = frame->sample_rate; s->inputFormat = frame->format;
    }
    if (!s->resampler) return 0;
    int64_t delay = swr_get_delay(s->resampler, s->inputRate);
    int capacity = (int)av_rescale_rnd(delay+(frame ? frame->nb_samples : 0),48000,s->inputRate,AV_ROUND_UP);
    if (capacity <= 0) return 0;
    if (capacity > 65536) return AVERROR(EFBIG);
    float *samples = av_malloc_array(capacity, 2*sizeof(float));
    if (!samples) return AVERROR(ENOMEM);
    uint8_t *out = (uint8_t *)samples;
    int count = swr_convert(s->resampler, &out, capacity,
        frame ? (const uint8_t **)frame->extended_data : NULL, frame ? frame->nb_samples : 0);
    if (count < 0) { av_free(samples); return count; }
    double pts = frame && frame->best_effort_timestamp != AV_NOPTS_VALUE ?
        frame->best_effort_timestamp * av_q2d(s->audioTimeBase) - s->origin - (double)delay/s->inputRate : s->nextAudioPTS;
    // Preserve a delayed audio track's original offset with actual silence,
    // rather than rebasing that track independently to zero.
    while (s->nextAudioPTS + 1.0/48000 < pts && entry.serial == atomic_load(&s->generation) && !atomic_load(&s->cancelled)) {
        int gap = (int)fmin(24000, floor((pts-s->nextAudioPTS)*48000));
        if (gap <= 0) break;
        float *silence = av_calloc(gap,2*sizeof(float));
        if (!silence) { av_free(samples); return AVERROR(ENOMEM); }
        putPCM(s,silence,gap,s->nextAudioPTS,entry.serial,entry.target);
        s->nextAudioPTS += gap/48000.0;
    }
    // Trim overlapping timestamps instead of scheduling duplicated source time.
    int trim=(int)fmin(count,ceil(fmax(0,s->nextAudioPTS-pts)*48000));
    if(trim) { count-=trim; pts+=trim/48000.0; memmove(samples,samples+2*trim,count*2*sizeof(float)); }
    s->nextAudioPTS = fmax(s->nextAudioPTS,pts+count/48000.0);
    putPCM(s,samples,count,pts,entry.serial,entry.target);
    return frame ? 0 : count;
}

static int emitVideo(CinevaFFmpegSession *s, AVFrame *frame, int serial, double target,
                     double *nextPTS) {
    if(atomic_load(&s->videoSuppressed)) return 0;
    double pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? *nextPTS :
        frame->best_effort_timestamp * av_q2d(s->videoTimeBase) - s->origin;
    if (!isfinite(pts)) pts = *nextPTS;
    AVRational durationBase = frame->time_base.num > 0 && frame->time_base.den > 0 ?
        frame->time_base : s->videoTimeBase;
    double step = frame->duration > 0 ? frame->duration * av_q2d(durationBase) : 0;
    if (!isfinite(step) || step <= 0)
        step = 1.0 / (isfinite(s->snapshot.fps) && s->snapshot.fps > 0 ? s->snapshot.fps : 30);
    *nextPTS = pts + step;
    if (serial != atomic_load(&s->generation)) return 0;
    if (pts + 0.001 < target) {
        pthread_mutex_lock(&s->mutex); s->snapshot.prerollFrames++; pthread_mutex_unlock(&s->mutex);
        return 0;
    }
    CVPixelBufferRef pixel = NULL;
    CinevaFFmpegSnapshot output = {0};
    int error = cineva_copy_video_surface(frame, s->videoParameters, &s->scale, &pixel, &output);
    if (error < 0) return error;
    pthread_mutex_lock(&s->mutex);
    int frameLimit = output.outputWidth * output.outputHeight > 1920 * 1080 ? 3 : FRAMES;
    while (s->frameCount >= frameLimit && !atomic_load(&s->cancelled) &&
           serial == atomic_load(&s->generation)) pthread_cond_wait(&s->changed, &s->mutex);
    if (atomic_load(&s->cancelled) || serial != atomic_load(&s->generation) || atomic_load(&s->videoSuppressed)) {
        CVPixelBufferRelease(pixel);
    } else {
        s->frames[(s->frameHead + s->frameCount++) % FRAMES] = (Frame){pixel, fmax(0, pts), step, serial};
        s->frameSeconds += step;
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
                         int video, Packet entry, double *nextPTS, int *failureStage) {
    int result;
    while ((result = avcodec_receive_frame(codec, frame)) >= 0) {
        if (atomic_load(&s->cancelled) || entry.serial != atomic_load(&s->generation)) {
            av_frame_unref(frame); return 0;
        }
        int error = 0;
        if (video) {
            pthread_mutex_lock(&s->mutex); s->snapshot.decodedVideoFrames++; pthread_mutex_unlock(&s->mutex);
            decoderStage(s, CinevaStageVideoSurface);
            error = emitVideo(s, frame, entry.serial, entry.target, nextPTS);
            if (error < 0) *failureStage = CinevaStageVideoSurface;
            decoderStage(s, CinevaStageVideoDecode);
        }
        else {
            pthread_mutex_lock(&s->mutex);
            s->snapshot.audioFrames++;
            pthread_mutex_unlock(&s->mutex);
            error = emitAudio(s, frame, entry);
        }
        av_frame_unref(frame);
        if (error < 0) return error;
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}
static int decodePacket(CinevaFFmpegSession *s, AVCodecContext *codec, AVFrame *frame,
                        int video, Packet entry, double *nextPTS, int *failureStage) {
    *failureStage = video ? CinevaStageVideoDecode : CinevaStageAudioDecode;
    decoderStage(s, *failureStage);
    int result = avcodec_send_packet(codec, entry.packet);
    if (result == AVERROR(EAGAIN)) {
        result = receiveFrames(s, codec, frame, video, entry, nextPTS, failureStage);
        if (result >= 0) result = avcodec_send_packet(codec, entry.packet);
    }
    if (result < 0 && result != AVERROR_EOF) return result;
    return receiveFrames(s, codec, frame, video, entry, nextPTS, failureStage);
}
static int openVideoDecoder(CinevaFFmpegSession *s);
static int allocateDecoder(const AVCodecParameters *params, AVRational timebase, AVCodecContext **context);
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
    int generation = atomic_fetch_add(&s->generation, 1) + 1;
    if (s->options.cancelIO) s->options.cancelIO(s->options.ioContext, generation);
    clearQueues(s);
    if (!atomic_load(&s->cancelled)) s->snapshot.status = 1;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->mutex);
    return 1;
}
static void *decodeLoop(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    AVFrame *frame = av_frame_alloc();
    if (!frame) { fail(s, AVERROR(ENOMEM), CinevaStageWorker); return NULL; }
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
        if(atomic_load(&s->videoSuppressed)) {
            if(entry.eof) {
                pthread_mutex_lock(&s->mutex); s->snapshot.videoDrained=1;
                if(s->snapshot.audioDrained) s->snapshot.status=2;
                pthread_mutex_unlock(&s->mutex);
            }
            av_packet_free(&entry.packet); continue;
        }
        if (serial != entry.serial) {
            avcodec_flush_buffers(s->video);
            serial = entry.serial; nextPTS = entry.target;
        }
        int result, failureStage = CinevaStageVideoDecode;
        int videoOperation = entry.eof || entry.packet->stream_index == s->videoIndex;
        if (entry.eof) {
            result = decodePacket(s, s->video, frame, 1, entry, &nextPTS, &failureStage);
            pthread_mutex_lock(&s->mutex);
            if (entry.serial == atomic_load(&s->generation) && result >= 0 &&
                !atomic_load(&s->cancelled)) {
                s->snapshot.videoDrained = 1;
                if (!s->hasAudioWorker || s->snapshot.audioDrained) s->snapshot.status = 2;
            }
            pthread_mutex_unlock(&s->mutex);
        } else {
            int isVideo = entry.packet->stream_index == s->videoIndex;
            if (!isVideo && !s->audio) { av_packet_free(&entry.packet); continue; }
            result = decodePacket(s, isVideo ? s->video : s->audio, frame, isVideo, entry, &nextPTS, &failureStage);
            if (result < 0 && !isVideo) { disableValidationAudio(s, result); result = 0; }
        }
        if(videoOperation && atomic_load(&s->videoSuppressed)) result=0;
        if (result < 0 && videoOperation && entry.serial == atomic_load(&s->generation) &&
            !atomic_load(&s->cancelled)) {
            int recovered = recoverSoftware(s, entry);
            if (recovered > 0) { av_packet_free(&entry.packet); continue; }
            if (recovered < 0) { result = recovered; failureStage = CinevaStageVideoOpen; }
        }
        av_packet_free(&entry.packet);
        if (result < 0 && entry.serial == atomic_load(&s->generation)) { fail(s, result, failureStage); break; }
        decoderStage(s, 0);
    }
    av_frame_free(&frame);
    return NULL;
}
static void *audioDecodeLoop(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    AVFrame *frame = av_frame_alloc();
    if (!frame) { fail(s,AVERROR(ENOMEM),CinevaStageWorker); return NULL; }
    int serial = -1, drained = -1;
    int activeIndex=s->audioSourceIndex;
    while (!atomic_load(&s->cancelled)) {
        pthread_mutex_lock(&s->mutex);
        while (!atomic_load(&s->cancelled) && !s->audioCount &&
            !(s->snapshot.demuxEOF && drained != atomic_load(&s->generation))) pthread_cond_wait(&s->changed,&s->mutex);
        if (atomic_load(&s->cancelled)) { pthread_mutex_unlock(&s->mutex); break; }
        Packet entry = {NULL,atomic_load(&s->generation),1,0,s->target};
        if (s->audioCount) {
            entry = s->audioPackets[s->audioHead]; s->audioHead=(s->audioHead+1)%PACKETS; s->audioCount--;
            s->audioBytes -= entry.packet->size; s->audioSeconds=fmax(0,s->audioSeconds-entry.duration);
        }
        pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
        if (entry.serial != atomic_load(&s->generation)) { av_packet_free(&entry.packet); continue; }
        if (serial != entry.serial) {
            int requested=atomic_load(&s->wantedAudioIndex);
            if (requested!=activeIndex) {
                int ordinal=-1;
                for (int i=0;i<s->trackCount;i++) if (s->audioTracks[i].index==requested) ordinal=i;
                AVCodecContext *candidate=NULL;
                int error=ordinal<0 ? AVERROR_STREAM_NOT_FOUND : allocateDecoder(s->audioParameters[ordinal],s->audioBases[ordinal],&candidate);
                if (error>=0) error=avcodec_open2(candidate,candidate->codec,NULL);
                if (error<0) {
                    avcodec_free_context(&candidate);
                    pthread_mutex_lock(&s->mutex); s->snapshot.audioWarningCode=error;
                    double position=s->playbackPosition; pthread_mutex_unlock(&s->mutex);
                    atomic_store(&s->wantedAudioIndex,activeIndex);
                    CinevaFFmpegSessionSeek(s,position);
                    av_packet_free(&entry.packet); continue;
                }
                avcodec_free_context(&s->audio); s->audio=candidate; activeIndex=requested;
                s->audioTimeBase=s->audioBases[ordinal];
            }
            avcodec_flush_buffers(s->audio); swr_free(&s->resampler);
            serial=entry.serial; s->nextAudioPTS=entry.target;
        }
        int stage=CinevaStageAudioDecode;
        double unused=0;
        int error=decodePacket(s,s->audio,frame,0,entry,&unused,&stage);
        if (entry.eof && error >= 0) {
            // Drain until Swr actually reports no remaining samples. A single
            // null input is not a general guarantee for every sample-rate ratio.
            int drains=0;
            do { error=emitAudio(s,NULL,entry); }
            while(error>0 && ++drains<16 && serial==atomic_load(&s->generation) && !atomic_load(&s->cancelled));
            if(error>0 && drains>=16) error=AVERROR_INVALIDDATA;
        }
        av_packet_free(&entry.packet);
        if (error < 0 && serial == atomic_load(&s->generation)) { fail(s,error,CinevaStageAudioDecode); break; }
        if (entry.eof) {
            pthread_mutex_lock(&s->mutex); drained=serial;
            if (serial==atomic_load(&s->generation)) {
                s->snapshot.audioDrained=1;
                if (s->snapshot.videoDrained) s->snapshot.status=2;
            }
            pthread_mutex_unlock(&s->mutex);
        }
    }
    av_frame_free(&frame); return NULL;
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
static int selectVideo(AVFormatContext *format) {
    int selected = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (selected >= 0 && !(format->streams[selected]->disposition & AV_DISPOSITION_ATTACHED_PIC))
        return selected;
    // av_find_best_stream also considers attached cover art. A still cover is
    // not a playable video track, even if its default flag/bitrate ranks first.
    selected = AVERROR_STREAM_NOT_FOUND;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *candidate = format->streams[i];
        if (candidate->codecpar->codec_type != AVMEDIA_TYPE_VIDEO ||
            (candidate->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        if (selected < 0 || (candidate->disposition & AV_DISPOSITION_DEFAULT)) selected = i;
    }
    return selected;
}
static void publishMedia(CinevaFFmpegSession *s) {
    if (s->videoIndex < 0) return;
    AVStream *video = s->format->streams[s->videoIndex];
    pthread_mutex_lock(&s->mutex);
    s->snapshot.width = video->codecpar->width; s->snapshot.height = video->codecpar->height;
    s->snapshot.videoCodec = video->codecpar->codec_id;
    s->snapshot.videoProfile = video->codecpar->profile;
    s->snapshot.videoStreamIndex = s->videoIndex;
    s->snapshot.audioCodec = s->audioSourceIndex >= 0 ? s->format->streams[s->audioSourceIndex]->codecpar->codec_id : AV_CODEC_ID_NONE;
    s->snapshot.fps = av_q2d(av_guess_frame_rate(s->format, video, NULL));
    s->snapshot.duration = s->format->duration > 0 ? (double)s->format->duration / AV_TIME_BASE : 0;
    s->snapshot.colorPrimaries = video->codecpar->color_primaries;
    s->snapshot.colorTransfer = video->codecpar->color_trc;
    s->snapshot.colorMatrix = video->codecpar->color_space;
    pthread_mutex_unlock(&s->mutex);
}
static int openInput(CinevaFFmpegSession *s, int extended) {
    AVDictionary *options = NULL;
    s->format = avformat_alloc_context();
    if (!s->format) return AVERROR(ENOMEM);
    if (s->options.read && s->options.size && s->options.ioContext) {
        uint8_t *buffer = av_malloc(65536);
        if (!buffer) return AVERROR(ENOMEM);
        s->customIO = avio_alloc_context(buffer, 65536, 0, s, customRead, NULL, customSeek);
        if (!s->customIO) { av_free(buffer); return AVERROR(ENOMEM); }
        s->customOffset = 0;
        s->format->pb = s->customIO;
        s->format->flags |= AVFMT_FLAG_CUSTOM_IO;
        s->customIO->seekable = AVIO_SEEKABLE_NORMAL;
    }
    s->format->interrupt_callback = (AVIOInterruptCB){ interrupted, s };
    av_dict_set(&options, "headers", s->headers, 0);
    // FFmpeg 8.0.2 defaults to closing HTTP connections and very short local
    // seeks. MP4 track/chunk switches can otherwise repeatedly pay TCP/TLS cost.
    av_dict_set(&options, "multiple_requests", "1", 0);
    av_dict_set(&options, "short_seek_size", "1048576", 0);
    av_dict_set(&options, "rw_timeout", "3000000", 0);
    av_dict_set(&options, "reconnect", "1", 0);
    av_dict_set(&options, "reconnect_on_network_error", "1", 0);
    av_dict_set(&options, "reconnect_max_retries", "2", 0);
    av_dict_set(&options, "reconnect_delay_max", "1", 0);
    av_dict_set(&options, "reconnect_delay_total_max", "2", 0);
    av_dict_set(&options, "protocol_whitelist", "http,https,tcp,tls,crypto", 0);
    av_dict_set(&options, "probesize", extended ? "8388608" : "2097152", 0);
    av_dict_set(&options, "analyzeduration", extended ? "8000000" : "3000000", 0);
    atomic_store(&s->deadline, av_gettime_relative() + 30000000);
    int result = avformat_open_input(&s->format, s->url, NULL, &options);
    av_dict_free(&options);
    return result;
}
static void *readLoop(void *opaque) {
    CinevaFFmpegSession *s = opaque;
    int result = 0, stage = CinevaStageOpen;
    // Keep signed URLs, cookies and credentials out of FFmpeg's process log.
    av_log_set_level(AV_LOG_QUIET);
    for (int attempt = 0; attempt < 2; attempt++) {
        stage = CinevaStageOpen; readerStage(s, stage);
        result = openInput(s, attempt);
        readerFinished(s, 0);
        if (result < 0) goto done;
        // Detect the actual demuxer, never a filename suffix or URL. Set before
        // stream probing too, so audio-only verification cannot cause MP4 seeks.
        int mov = s->format->iformat == av_find_input_format("mov");
        if (mov) {
            result = av_opt_set_int(s->format->priv_data, "interleaved_read", s->videoOnly && s->options.sequentialVideoOnly ? 0 : 1, 0);
            if (result < 0) goto done;
        }
        if (s->videoOnly) for (unsigned i = 0; i < s->format->nb_streams; i++) {
            AVStream *stream = s->format->streams[i];
            if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO ||
                (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) stream->discard = AVDISCARD_ALL;
        }
        if (s->videoOnly) {
            // find_stream_info may try opening an audio decoder even for a
            // discarded stream. Restrict its internal probe decoders too.
            AVBPrint names;
            av_bprint_init(&names, 128, AV_BPRINT_SIZE_UNLIMITED);
            void *iterator = NULL;
            const AVCodec *codec;
            while ((codec = av_codec_iterate(&iterator))) {
                if (av_codec_is_decoder(codec) && codec->type == AVMEDIA_TYPE_VIDEO)
                    av_bprintf(&names, "%s%s", names.len ? "," : "", codec->name);
            }
            int complete = av_bprint_is_complete(&names);
            result = complete ? av_opt_set(s->format, "codec_whitelist", names.str, 0) : AVERROR(ENOMEM);
            av_bprint_finalize(&names, NULL);
            if (result < 0) goto done;
        }
        pthread_mutex_lock(&s->mutex);
        s->snapshot.movInterleavedRead = mov ? !(s->videoOnly && s->options.sequentialVideoOnly) : -1;
        snprintf(s->snapshot.container, sizeof(s->snapshot.container), "%s", s->format->iformat->name);
        pthread_mutex_unlock(&s->mutex);
        stage = CinevaStageProbe; readerStage(s, stage);
        result = avformat_find_stream_info(s->format, NULL);
        readerFinished(s, 0);
        s->videoIndex = selectVideo(s->format);
        s->audioSourceIndex = av_find_best_stream(s->format, AVMEDIA_TYPE_AUDIO, -1, s->videoIndex, NULL, 0);
        s->audioIndex = s->videoOnly ? -1 : s->audioSourceIndex;
        pthread_mutex_lock(&s->mutex); s->snapshot.audioDemux = s->audioIndex >= 0; pthread_mutex_unlock(&s->mutex);
        // Keep partial metadata even when probing or decoder opening fails.
        publishMedia(s);
        int incomplete = s->videoIndex < 0;
        if (!incomplete) {
            AVCodecParameters *params = s->format->streams[s->videoIndex]->codecpar;
            incomplete = params->codec_id == AV_CODEC_ID_NONE || params->width <= 0 || params->height <= 0;
        }
        // Retry only incomplete/invalid probing, once, from a fresh demuxer.
        // Ordinary files keep the existing startup budget; transport failures
        // and cancellation are never disguised as format-recovery attempts.
        if (!attempt && !atomic_load(&s->cancelled) &&
            (result == AVERROR_INVALIDDATA || (result >= 0 && incomplete))) {
            closeInput(s);
            pthread_mutex_lock(&s->mutex); s->snapshot.probeRetried = 1; pthread_mutex_unlock(&s->mutex);
            continue;
        }
        if (result < 0) goto done;
        stage = CinevaStageSelectVideo; readerStage(s, stage);
        if (incomplete) { result = s->videoIndex < 0 ? s->videoIndex : AVERROR_INVALIDDATA; goto done; }
        break;
    }
    if (atomic_load(&s->cancelled)) goto done;
    // A dropped packet after av_read_frame is already downloaded. Discard
    // unused tracks at the demuxer instead, before MP4 seeks/reads their bytes.
    // Standard A keeps both tracks; video-only B never queues audio packets.
    for (unsigned i = 0; i < s->format->nb_streams; i++) {
        s->format->streams[i]->discard = (int)i == s->videoIndex || (int)i == s->audioIndex ?
            AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
    AVStream *video = s->format->streams[s->videoIndex];
    s->videoTimeBase = video->time_base;
    s->videoParameters = avcodec_parameters_alloc();
    if (!s->videoParameters) { result = AVERROR(ENOMEM); goto done; }
    result = avcodec_parameters_copy(s->videoParameters, video->codecpar);
    if (result < 0) goto done;
    stage = CinevaStageVideoOpen; readerStage(s, stage);
    // Dolby's per-frame pipeline is a later phase; preserve the existing native path.
    if (av_packet_side_data_get(s->videoParameters->coded_side_data,
        s->videoParameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)) {
        result = -70001; goto done;
    }
    result = openVideoDecoder(s);
    if (result < 0) goto done;
    if (s->audioIndex >= 0) {
        stage = CinevaStageAudioOpen; readerStage(s, stage);
        AVStream *audio = s->format->streams[s->audioIndex];
        s->audioTimeBase = audio->time_base;
        result = allocateDecoder(audio->codecpar, audio->time_base, &s->audio);
        if (result >= 0) result = avcodec_open2(s->audio, s->audio->codec, NULL);
        if (result < 0) {
            if (s->options.outputAudio) goto done;
            disableValidationAudio(s, result); result = 0;
            s->format->streams[s->audioIndex]->discard=AVDISCARD_ALL;
            s->audioIndex=-1;
        }
    }
    for (unsigned i=0;i<s->format->nb_streams && s->trackCount<32;i++) {
        AVStream *stream=s->format->streams[i];
        if (stream->codecpar->codec_type!=AVMEDIA_TYPE_AUDIO) continue;
        int n=s->trackCount;
        s->audioParameters[n]=avcodec_parameters_alloc();
        if (!s->audioParameters[n] || avcodec_parameters_copy(s->audioParameters[n],stream->codecpar)<0) { result=AVERROR(ENOMEM); goto done; }
        s->audioBases[n]=stream->time_base;
        CinevaFFmpegAudioTrack track={.index=(int)i,.codec=stream->codecpar->codec_id,
          .channels=stream->codecpar->ch_layout.nb_channels,.sampleRate=stream->codecpar->sample_rate};
        AVDictionaryEntry *language=av_dict_get(stream->metadata,"language",NULL,0), *title=av_dict_get(stream->metadata,"title",NULL,0);
        snprintf(track.language,sizeof(track.language),"%s",language?language->value:"und");
        snprintf(track.title,sizeof(track.title),"%s",title?title->value:"");
        pthread_mutex_lock(&s->mutex); s->audioTracks[n]=track; s->trackCount++; pthread_mutex_unlock(&s->mutex);
    }
    atomic_store(&s->wantedAudioIndex,s->audioIndex);
    s->origin = s->format->start_time != AV_NOPTS_VALUE ? (double)s->format->start_time / AV_TIME_BASE :
        (video->start_time != AV_NOPTS_VALUE ? video->start_time * av_q2d(video->time_base) : 0);
    if(s->options.outputAudio && !s->videoOnly) {
        CinevaSubtitles *subtitles=cineva_sub_create(s->format,s->origin,s->videoParameters->width,s->videoParameters->height);
        pthread_mutex_lock(&s->mutex); s->subtitles=subtitles; pthread_mutex_unlock(&s->mutex);
    }
    if (s->audio) {
        s->hasAudioWorker = 1;
        if (pthread_create(&s->audioWorker,NULL,audioDecodeLoop,s)) {
            s->hasAudioWorker=0; result=AVERROR(ENOMEM); goto done;
        }
    }
    pthread_mutex_lock(&s->mutex);
    s->snapshot.audioEnabled = s->audio && s->options.outputAudio;
    pthread_mutex_unlock(&s->mutex);
    const AVPacketSideData *matrix = av_packet_side_data_get(video->codecpar->coded_side_data,
        video->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    pthread_mutex_lock(&s->mutex);
    s->snapshot.rotation = matrix && matrix->size >= 9 * sizeof(int32_t) ?
        -av_display_rotation_get((const int32_t *)matrix->data) : 0;
    if (!atomic_load(&s->cancelled)) s->snapshot.status = 1;
    pthread_mutex_unlock(&s->mutex);
    stage = CinevaStageWorker; readerStage(s, stage);
    if (pthread_create(&s->decoder, NULL, decodeLoop, s)) { result = AVERROR(ENOMEM); goto done; }
    s->hasDecoder = 1;
    int serial = -1, eof = 0, videoSuppressed=-1;
    double target = 0;
    while (!atomic_load(&s->cancelled)) {
        int suppressed=atomic_load(&s->videoSuppressed);
        if(suppressed!=videoSuppressed) {
            s->format->streams[s->videoIndex]->discard=suppressed?AVDISCARD_ALL:AVDISCARD_DEFAULT;
            int subtitle=cineva_sub_index(s->subtitles);
            if(subtitle>=0) s->format->streams[subtitle]->discard=suppressed?AVDISCARD_ALL:AVDISCARD_DEFAULT;
            videoSuppressed=suppressed;
        }
        int wanted = atomic_load(&s->generation);
        if (wanted != serial) {
            if (!s->videoOnly) {
                s->audioIndex=atomic_load(&s->wantedAudioIndex);
                for (unsigned i=0;i<s->format->nb_streams;i++)
                    s->format->streams[i]->discard=((int)i==s->videoIndex || (int)i==s->audioIndex ||
                        (!suppressed && (int)i==cineva_sub_index(s->subtitles)))?AVDISCARD_DEFAULT:AVDISCARD_ALL;
                pthread_mutex_lock(&s->mutex); s->snapshot.selectedAudioIndex=s->audioIndex; pthread_mutex_unlock(&s->mutex);
                s->format->streams[s->videoIndex]->discard=suppressed?AVDISCARD_ALL:AVDISCARD_DEFAULT;
            }
            pthread_mutex_lock(&s->mutex);
            target = s->target;
            clearQueues(s);
            cineva_sub_reset(s->subtitles,wanted);
            if (!atomic_load(&s->cancelled)) s->snapshot.status = 1;
            pthread_cond_broadcast(&s->changed);
            pthread_mutex_unlock(&s->mutex);
            atomic_store(&s->interruptSeek, 0);
            if (serial >= 0 || target > 0) {
                stage = CinevaStageSeek; readerStage(s, stage);
                atomic_store(&s->ioGeneration, wanted);
                atomic_store(&s->interruptSeek, 1);
                if (s->format->pb) { s->format->pb->error = 0; s->format->pb->eof_reached = 0; }
                int64_t stamp = (int64_t)((target + s->origin) * AV_TIME_BASE);
                atomic_store(&s->deadline, av_gettime_relative() + 10000000);
                int64_t videoStamp = av_rescale_q(stamp, AV_TIME_BASE_Q, s->videoTimeBase);
                result = avformat_seek_file(s->format, s->videoIndex, INT64_MIN, videoStamp, videoStamp, 0);
                if (result < 0 && result != AVERROR_EXIT && wanted == atomic_load(&s->generation) && !atomic_load(&s->cancelled) &&
                    av_gettime_relative() < atomic_load(&s->deadline)) {
                    // Some indexes implement the older keyframe seek more
                    // reliably. Keep the same target and bounded I/O deadline.
                    if (s->format->pb) { s->format->pb->error = 0; s->format->pb->eof_reached = 0; }
                    result = av_seek_frame(s->format, s->videoIndex, videoStamp, AVSEEK_FLAG_BACKWARD);
                    pthread_mutex_lock(&s->mutex); s->snapshot.seekFallbacks++; pthread_mutex_unlock(&s->mutex);
                }
                atomic_store(&s->interruptSeek, 0);
                readerFinished(s, 0);
                if (wanted != atomic_load(&s->generation)) { result = 0; continue; }
                if (result < 0) goto done;
                // Both seek APIs flush internally. A second avformat_flush can
                // discard packets/attached state the demuxer buffered at seek.
            }
            serial = wanted; eof = 0;
            s->previousPacketEnd = -1;
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
        stage = CinevaStageRead; readerStage(s, stage);
        atomic_store(&s->deadline, av_gettime_relative() + 10000000);
        result = av_read_frame(s->format, packet);
        readerFinished(s, 1);
        atomic_store(&s->interruptSeek, 0);
        if (serial != atomic_load(&s->generation)) { av_packet_free(&packet); continue; }
        if (result == AVERROR_EOF) {
            pthread_mutex_lock(&s->mutex);
            if (serial == atomic_load(&s->generation)) s->snapshot.demuxEOF = 1;
            pthread_mutex_unlock(&s->mutex);
            av_packet_free(&packet);
            putPacket(s, (Packet){NULL, serial, 1, 0, target}); eof = 1; continue;
        }
        if (result < 0) { av_packet_free(&packet); goto done; }
        if(packet->stream_index==s->videoIndex && atomic_load(&s->videoSuppressed)) { av_packet_free(&packet); continue; }
        if (packet->stream_index == cineva_sub_index(s->subtitles)) {
            if(!atomic_load(&s->videoSuppressed)) cineva_sub_put(s->subtitles,packet,serial);
            av_packet_free(&packet); continue;
        }
        if (packet->stream_index != s->videoIndex && packet->stream_index != s->audioIndex) {
            av_packet_free(&packet); continue;
        }
        if (packet->size > BYTE_LIMIT) { av_packet_free(&packet); result = AVERROR(EFBIG); goto done; }
        pthread_mutex_lock(&s->mutex);
        s->lastPacketUs = av_gettime_relative();
        if (packet->pos >= 0) {
            if (s->previousPacketEnd >= 0 && packet->pos < s->previousPacketEnd) {
                s->snapshot.backwardPacketJumps++;
                int64_t distance = s->previousPacketEnd - packet->pos;
                s->snapshot.backwardJumpBytesTotal += distance;
                s->snapshot.largestBackwardJump = FFMAX(s->snapshot.largestBackwardJump, distance);
            }
            if (s->previousPacketEnd >= 0 && packet->pos > s->previousPacketEnd) {
                int64_t gap = packet->pos - s->previousPacketEnd;
                s->snapshot.forwardGapBytesTotal += gap;
                s->snapshot.largestForwardGap = FFMAX(s->snapshot.largestForwardGap, gap);
                if (gap > 1048576) s->snapshot.largeForwardPacketJumps++;
            }
            s->snapshot.lastPacketPosition = packet->pos;
            s->previousPacketEnd = packet->pos + packet->size;
        }
        pthread_mutex_unlock(&s->mutex);
        // Reserve video time, not summed audio+video durations. Summing both
        // used to report four seconds while often retaining only two seconds.
        double seconds = packet->duration > 0 ? packet->duration *
            av_q2d(s->format->streams[packet->stream_index]->time_base) : 0;
        // Keyframe preroll before the requested position is not playable runway.
        if (seconds > 0 && packet->pts != AV_NOPTS_VALUE) {
            double pts = packet->pts * av_q2d(s->format->streams[packet->stream_index]->time_base) - s->origin;
            seconds = fmax(0, fmin(seconds, pts + seconds - target));
        }
        putPacket(s, (Packet){packet, serial, 0, fmin(seconds, 8.0), target});
    }
done:
    readerFinished(s, 0);
    if (result < 0 && !atomic_load(&s->cancelled)) fail(s, result, stage);
    if (s->hasDecoder) pthread_join(s->decoder, NULL);
    if (s->hasAudioWorker) pthread_join(s->audioWorker, NULL);
    return NULL;
}

CinevaFFmpegSession *CinevaFFmpegSessionCreate(const char *url, const char *headers, double startTime, CinevaFFmpegSessionOptions options) {
    if (strncmp(url, "https://", 8) && strncmp(url, "http://", 7)) return NULL;
    CinevaFFmpegSession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    pthread_mutex_init(&s->mutex, NULL); pthread_cond_init(&s->changed, NULL);
    atomic_init(&s->cancelled, 0); atomic_init(&s->generation, 1);
    atomic_init(&s->wantedAudioIndex,-1);
    atomic_init(&s->videoSuppressed,0);
    atomic_init(&s->interruptSeek, 0); atomic_init(&s->ioGeneration, 1);
    atomic_init(&s->deadline, 0);
    s->url = strdup(url); s->headers = strdup(headers);
    s->target = isfinite(startTime) ? fmax(0, startTime) : 0;
    s->playbackPosition = s->target;
    s->snapshot.recoveryTarget = s->target;
    s->snapshot.videoStreamIndex = -1;
    s->snapshot.videoProfile = AV_PROFILE_UNKNOWN;
    s->previousPacketEnd = -1;
    s->snapshot.lastPacketPosition = -1;
    s->videoOnly = !!options.videoOnly;
    s->options = options;
    s->snapshot.videoOnly = s->videoOnly;
    s->snapshot.movInterleavedRead = -1;
    s->audioIndex = s->audioSourceIndex = -1;
    s->disableHardware = !options.preferHardware;
    s->snapshot.fallbackReason = options.preferHardware ? 0 : 5;
    if (!s->url || !s->headers || pthread_create(&s->reader, NULL, readLoop, s)) {
        CinevaFFmpegSessionDestroy(s); return NULL;
    }
    s->hasReader = 1;
    return s;
}
void CinevaFFmpegSessionCancel(CinevaFFmpegSession *s) {
    atomic_store(&s->cancelled, 1);
    if (s->options.cancelIO) s->options.cancelIO(s->options.ioContext, -1);
    pthread_mutex_lock(&s->mutex); pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
}
void CinevaFFmpegSessionDestroy(CinevaFFmpegSession *s) {
    CinevaFFmpegSessionCancel(s);
    if (s->hasReader) pthread_join(s->reader, NULL);
    cineva_sub_destroy(s->subtitles);
    clearQueues(s);
    sws_freeContext(s->scale);
    swr_free(&s->resampler); av_channel_layout_uninit(&s->inputLayout);
    avcodec_free_context(&s->video); avcodec_free_context(&s->audio);
    avcodec_parameters_free(&s->videoParameters);
    for (int i=0;i<32;i++) avcodec_parameters_free(&s->audioParameters[i]);
    closeInput(s);
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
    if (s->options.cancelIO) s->options.cancelIO(s->options.ioContext, serial);
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
void CinevaFFmpegSessionSetVideoActive(CinevaFFmpegSession *s,int active) {
    if(!s->options.outputAudio) return;
    atomic_store(&s->videoSuppressed,!active);
    pthread_mutex_lock(&s->mutex);
    if(!active) {
        for(int i=0;i<s->packetCount;i++) av_packet_free(&s->packets[(s->packetHead+i)%PACKETS].packet);
        for(int i=0;i<s->frameCount;i++) CVPixelBufferRelease(s->frames[(s->frameHead+i)%FRAMES].buffer);
        s->packetHead=s->packetCount=s->frameHead=s->frameCount=0;
        s->packetBytes=0; s->packetSeconds=s->frameSeconds=0;
        if(s->snapshot.demuxEOF) {
            s->snapshot.videoDrained=1;
            if(s->snapshot.audioDrained) s->snapshot.status=2;
        }
    }
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
}
typedef struct { double start,end; } TimeRange;
static int compareRange(const void *a,const void *b) {
    double x=((const TimeRange *)a)->start,y=((const TimeRange *)b)->start;
    return x<y?-1:x>y?1:0;
}
static void queueRange(CinevaFFmpegSession *s, int audio, double *start, double *end) {
    TimeRange ranges[PACKETS+PCM_LIMIT+FRAMES]; int n=0;
    Packet *packets=audio?s->audioPackets:s->packets;
    int count=audio?s->audioCount:s->packetCount,head=audio?s->audioHead:s->packetHead;
    for (int i=0;i<count;i++) {
        Packet p=packets[(head+i)%PACKETS];
        if (!p.packet || p.packet->pts==AV_NOPTS_VALUE) continue;
        AVRational base=s->videoTimeBase;
        if (audio) for (int t=0;t<s->trackCount;t++) if (s->audioTracks[t].index==p.packet->stream_index) base=s->audioBases[t];
        double pts=p.packet->pts*av_q2d(base)-s->origin;
        double finish=pts+fmax(0,p.packet->duration*av_q2d(base));
        if(finish<p.target) continue;
        // A timestamp without duration is still a known presentation point.
        // Adjacent packet points establish a span; do not invent a tail duration
        // or erase every compressed packet in containers with duration == 0.
        ranges[n++]=(TimeRange){fmax(pts,p.target),finish};
    }
    if (audio) for (int i=0;i<s->pcmCount;i++) {
        PCM p=s->pcm[(s->pcmHead+i)%PCM_LIMIT]; ranges[n++]=(TimeRange){p.pts,p.pts+p.count/48000.0};
    } else for (int i=0;i<s->frameCount;i++) {
        Frame f=s->frames[(s->frameHead+i)%FRAMES]; ranges[n++]=(TimeRange){f.pts,f.pts+f.duration};
    }
    *start=*end=-1;
    if (!n) return;
    qsort(ranges,n,sizeof(TimeRange),compareRange);
    *start=ranges[0].start; *end=ranges[0].end;
    double tolerance=!audio && isfinite(s->snapshot.fps) && s->snapshot.fps>0 ?
        fmax(0.05,1.25/s->snapshot.fps):0.05;
    for (int i=1;i<n;i++) {
        if (ranges[i].start>*end+tolerance) break;
        *end=fmax(*end,ranges[i].end);
    }
}
void CinevaFFmpegSessionSnapshot(CinevaFFmpegSession *s, CinevaFFmpegSnapshot *snapshot) {
    pthread_mutex_lock(&s->mutex);
    *snapshot = s->snapshot;
    snapshot->serial = atomic_load(&s->generation);
    snapshot->packetBytes = s->packetBytes; snapshot->packetCount = s->packetCount;
    snapshot->frameCount = s->frameCount; snapshot->queuedSeconds = s->packetSeconds;
    snapshot->decodedQueueSeconds = s->frameSeconds;
    snapshot->audioPacketCount=s->audioCount; snapshot->audioPacketBytes=s->audioBytes;
    snapshot->audioQueuedSeconds=s->audioSeconds; snapshot->pcmSeconds=s->pcmSeconds;
    snapshot->pcmCount=s->pcmCount;
    queueRange(s,0,&snapshot->videoStart,&snapshot->videoEnd);
    queueRange(s,1,&snapshot->audioStart,&snapshot->audioEnd);
    int64_t now = av_gettime_relative();
    snapshot->activeIOSeconds = s->ioStartedUs ? (now - s->ioStartedUs) / 1000000.0 : 0;
    snapshot->lastPacketAge = s->lastPacketUs ? (now - s->lastPacketUs) / 1000000.0 : -1;
    pthread_mutex_unlock(&s->mutex);
}
CVPixelBufferRef CinevaFFmpegSessionCopyFrame(CinevaFFmpegSession *s, double *pts, double *duration, int *serial) {
    pthread_mutex_lock(&s->mutex);
    CVPixelBufferRef result = NULL;
    if (s->frameCount) {
        Frame frame = s->frames[s->frameHead]; s->frameHead = (s->frameHead + 1) % FRAMES;
        s->frameCount--; *pts = frame.pts; *duration = frame.duration; *serial = frame.serial; result = frame.buffer;
        s->frameSeconds = fmax(0, s->frameSeconds - frame.duration);
    }
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
    return result;
}
const char *CinevaFFmpegCodecName(int codec) { return avcodec_get_name(codec); }
static CinevaSubtitles *subtitles(CinevaFFmpegSession *s) {
    pthread_mutex_lock(&s->mutex); CinevaSubtitles *value=s->subtitles; pthread_mutex_unlock(&s->mutex); return value;
}
int CinevaFFmpegSessionSubtitleTrackCount(CinevaFFmpegSession *s) { return cineva_sub_count(subtitles(s)); }
int CinevaFFmpegSessionSubtitleTrack(CinevaFFmpegSession *s,int ordinal,CinevaFFmpegSubtitleTrack *track) {
    return cineva_sub_track(subtitles(s),ordinal,track);
}
int CinevaFFmpegSessionSubtitleError(CinevaFFmpegSession *s) { return cineva_sub_error(subtitles(s)); }
int CinevaFFmpegSessionSelectSubtitle(CinevaFFmpegSession *s,int index) {
    if(cineva_sub_select(subtitles(s),index)<0) return -1;
    pthread_mutex_lock(&s->mutex); double position=s->playbackPosition; pthread_mutex_unlock(&s->mutex);
    return CinevaFFmpegSessionSeek(s,position);
}
CVPixelBufferRef CinevaFFmpegSessionCopySubtitle(CinevaFFmpegSession *s,double time,int serial,int *changed) {
    CVPixelBufferRef pixel=NULL; *changed=cineva_sub_render(subtitles(s),time,serial,&pixel); return pixel;
}
int CinevaFFmpegSessionExternalSubtitle(CinevaFFmpegSession *s,const uint8_t *data,int size,const char *format) {
    return cineva_sub_external(subtitles(s),data,size,format);
}
int CinevaFFmpegSessionAudioTrackCount(CinevaFFmpegSession *s) {
    pthread_mutex_lock(&s->mutex); int count=s->trackCount; pthread_mutex_unlock(&s->mutex); return count;
}
int CinevaFFmpegSessionAudioTrack(CinevaFFmpegSession *s,int ordinal,CinevaFFmpegAudioTrack *track) {
    pthread_mutex_lock(&s->mutex); int ok=ordinal>=0 && ordinal<s->trackCount;
    if (ok) *track=s->audioTracks[ordinal]; pthread_mutex_unlock(&s->mutex); return ok;
}
int CinevaFFmpegSessionSelectAudio(CinevaFFmpegSession *s,int index) {
    pthread_mutex_lock(&s->mutex);
    int found=0;
    for (int i=0;i<s->trackCount;i++) if (s->audioTracks[i].index==index && avcodec_find_decoder(s->audioTracks[i].codec)) found=1;
    double position=s->playbackPosition;
    pthread_mutex_unlock(&s->mutex);
    if (!found || s->videoOnly || !s->options.outputAudio) return -1;
    atomic_store(&s->wantedAudioIndex,index);
    return CinevaFFmpegSessionSeek(s,position);
}
int CinevaFFmpegSessionCopyAudio(CinevaFFmpegSession *s, float *samples, int capacity, double *pts, int *serial) {
    pthread_mutex_lock(&s->mutex);
    int count=0;
    if (s->pcmCount) {
        PCM item=s->pcm[s->pcmHead];
        if (item.count <= capacity) {
            memcpy(samples,item.samples,item.count*2*sizeof(float));
            count=item.count; *pts=item.pts; *serial=item.serial;
            av_free(item.samples); s->pcmHead=(s->pcmHead+1)%PCM_LIMIT; s->pcmCount--;
            s->pcmSeconds=fmax(0,s->pcmSeconds-count/48000.0);
        }
    }
    pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->mutex);
    return count;
}
void CinevaFFmpegErrorText(int code, char *buffer, int capacity) {
    if (capacity > 0) av_strerror(code, buffer, capacity);
}
