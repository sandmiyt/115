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

// Hardware-preferred validation workers. Optional audio decode remains available
// for standard A, but videoOnly excludes it. No libav types cross this ABI.
typedef struct CinevaFFmpegSession CinevaFFmpegSession;
typedef struct {
    int preferHardware;
    int videoOnly; // Validation defaults true; false retains audio decode capability.
} CinevaFFmpegSessionOptions;
typedef struct {
    int status; // 0 opening, 1 decoding, 2 drained, -1 failed
    int errorCode;
    int serial;
    int width, height, videoCodec, audioCodec;
    int packetCount, frameCount;
    int64_t packetBytes, videoFrames, audioFrames;
    double duration, fps, rotation, queuedSeconds;
    int decoderType; // 0 not yet observed, 1 FFmpeg software, 2 required VideoToolbox hardware
    int fallbackReason; // 0 none, 1 no device/codec support, 2 device init, 3 format init, 4 decode failure, 5 forced software
    int outputWidth, outputHeight, outputBitDepth;
    int colorPrimaries, colorTransfer, colorMatrix, hasMastering, hasContentLight;
    int64_t hardwareFrames, softwareFrames;
    double recoveryTarget;
    // Failure is captured at its origin; worker activity cannot overwrite it.
    int failureStage, readerStage, decoderStage;
    int probeRetried, seekFallbacks, audioWarningCode;
    int64_t decodedVideoFrames, prerollFrames;
    int videoProfile, videoStreamIndex;
    char container[48];
    int64_t ioBytesRead, ioPosition, lastPacketPosition;
    int backwardPacketJumps, largeForwardPacketJumps;
    double activeIOSeconds, lastReadSeconds, lastPacketAge;
    int videoOnly, audioDemux, movInterleavedRead; // MOV: -1 not applicable, 0 OFF, 1 ON
    double decodedQueueSeconds;
    int demuxEOF, readerBackpressured;
    int64_t backwardJumpBytesTotal, largestBackwardJump;
    int64_t forwardGapBytesTotal, largestForwardGap;
    int64_t packetReadCount;
    double averageReadFrameDuration, maximumReadFrameDuration;
} CinevaFFmpegSnapshot;
enum {
    CinevaStageOpen = 1, CinevaStageProbe, CinevaStageSelectVideo,
    CinevaStageVideoOpen, CinevaStageAudioOpen, CinevaStageSeek,
    CinevaStageRead, CinevaStageVideoDecode, CinevaStageAudioDecode,
    CinevaStageVideoSurface, CinevaStageWorker
};
CinevaFFmpegSession * _Nullable CinevaFFmpegSessionCreate(
    const char * _Nonnull url, const char * _Nonnull headers, double startTime, CinevaFFmpegSessionOptions options);
void CinevaFFmpegSessionCancel(CinevaFFmpegSession * _Nonnull session);
// Must run off the main thread, after the consumer has stopped using session.
void CinevaFFmpegSessionDestroy(CinevaFFmpegSession * _Nonnull session);
int CinevaFFmpegSessionSeek(CinevaFFmpegSession * _Nonnull session, double seconds);
void CinevaFFmpegSessionSetPosition(CinevaFFmpegSession * _Nonnull session, double seconds);
void CinevaFFmpegSessionSnapshot(CinevaFFmpegSession * _Nonnull session,
    CinevaFFmpegSnapshot * _Nonnull snapshot);
CVPixelBufferRef _Nullable CinevaFFmpegSessionCopyFrame(CinevaFFmpegSession * _Nonnull session,
    double * _Nonnull pts, double * _Nonnull duration, int * _Nonnull serial) CF_RETURNS_RETAINED;
const char * _Nonnull CinevaFFmpegCodecName(int codec);
void CinevaFFmpegErrorText(int code, char * _Nonnull buffer, int capacity);

#ifdef __cplusplus
}
#endif
#endif
