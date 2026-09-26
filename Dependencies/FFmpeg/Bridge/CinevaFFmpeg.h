#ifndef CINEVA_FFMPEG_H
#define CINEVA_FFMPEG_H
#include <CoreVideo/CoreVideo.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char * _Nonnull CinevaFFmpegVersion(void);
const char * _Nonnull CinevaFFmpegConfiguration(void);
const char * _Nonnull CinevaFFmpegLicense(void);
int CinevaFFmpegHasDecoder(const char * _Nonnull name);
int CinevaFFmpegHasDemuxer(const char * _Nonnull name);
// Compiled API capability only; NOT a physical-device hardware decode test.
int CinevaFFmpegHasVideoToolbox(const char * _Nonnull decoder);
// Allocate/free actual libavformat/libavcodec/libswresample/libswscale objects.
// No network, media playback or hardware session is opened in Phase 2.
int CinevaFFmpegRuntimeCheck(void);

// Phase 3: independent demux/decode workers. Audio is decoded for validation,
// but not rendered until the audio-clock phase. No libav types cross this ABI.
typedef struct CinevaFFmpegSession CinevaFFmpegSession;
typedef struct {
    int status; // 0 opening, 1 decoding, 2 drained, -1 failed
    int errorCode;
    int serial;
    int width, height, videoCodec, audioCodec;
    int packetCount, frameCount;
    int64_t packetBytes, videoFrames, audioFrames;
    double duration, fps, rotation, queuedSeconds;
} CinevaFFmpegSnapshot;
CinevaFFmpegSession * _Nullable CinevaFFmpegSessionCreate(
    const char * _Nonnull url, const char * _Nonnull headers, double startTime);
void CinevaFFmpegSessionCancel(CinevaFFmpegSession * _Nonnull session);
// Must run off the main thread, after the consumer has stopped using session.
void CinevaFFmpegSessionDestroy(CinevaFFmpegSession * _Nonnull session);
int CinevaFFmpegSessionSeek(CinevaFFmpegSession * _Nonnull session, double seconds);
void CinevaFFmpegSessionSnapshot(CinevaFFmpegSession * _Nonnull session,
    CinevaFFmpegSnapshot * _Nonnull snapshot);
CVPixelBufferRef _Nullable CinevaFFmpegSessionCopyFrame(CinevaFFmpegSession * _Nonnull session,
    double * _Nonnull pts, int * _Nonnull serial) CF_RETURNS_RETAINED;
const char * _Nonnull CinevaFFmpegCodecName(int codec);

#ifdef __cplusplus
}
#endif
#endif
