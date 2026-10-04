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
typedef int (*CinevaFFmpegRead)(void * _Nonnull context, int64_t offset,
    uint8_t * _Nonnull buffer, int capacity, int generation);
typedef int64_t (*CinevaFFmpegSize)(void * _Nonnull context);
typedef void (*CinevaFFmpegCancelIO)(void * _Nonnull context, int generation);
typedef struct {
    int preferHardware;
    int videoOnly; // Validation defaults true; false retains audio decode capability.
    int sequentialVideoOnly; // Applies only to video-only MOV, never audio playback.
    int outputAudio;
    int preview; // Independent video-only context; one retained full-resolution frame.
    void * _Nullable ioContext;
    CinevaFFmpegRead _Nullable read;
    CinevaFFmpegSize _Nullable size;
    CinevaFFmpegCancelIO _Nullable cancelIO;
    int forceFullProbe; // Diagnostic before/after comparison; no shipping UI.
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
    char failureFunction[48];
    int64_t lastReadOffset, lastSeekOffset, lastSeekResult;
    int lastReadCapacity, lastReadResult, lastSeekWhence;
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
    int audioEnabled, audioDrained, videoDrained;
    int audioPacketCount, pcmCount;
    int64_t audioPacketBytes;
    double audioQueuedSeconds, pcmSeconds;
    double audioDecodedTime, audioStart, audioEnd, videoStart, videoEnd;
    int selectedAudioIndex;
    int audioProfile, atmosMetadataDetected;
    double firstByteSeconds, openSeconds, probeSeconds, firstDecodedSeconds;
    double seekLookupSeconds, seekPrerollSeconds; // Current generation, -1 until ready.
    int probeSkipped; // Complete indexed MP4 metadata; all other inputs probe normally.
    int64_t probeReadBytes;
    double videoOpenSeconds, audioOpenSeconds; // Stage durations, not cumulative timestamps.
} CinevaFFmpegSnapshot;
typedef struct { int index, codec, channels, sampleRate; char language[32], title[128]; } CinevaFFmpegAudioTrack;
typedef struct { int index, codec; char language[32], title[128]; } CinevaFFmpegSubtitleTrack;
int CinevaFFmpegSessionSubtitleTrackCount(CinevaFFmpegSession * _Nonnull session);
int CinevaFFmpegSessionSubtitleTrack(CinevaFFmpegSession * _Nonnull session, int ordinal, CinevaFFmpegSubtitleTrack * _Nonnull track);
int CinevaFFmpegSessionSelectSubtitle(CinevaFFmpegSession * _Nonnull session, int streamIndex);
int CinevaFFmpegSessionSubtitleError(CinevaFFmpegSession * _Nonnull session);
CVPixelBufferRef _Nullable CinevaFFmpegSessionCopySubtitle(CinevaFFmpegSession * _Nonnull session,
    double time, int serial, int * _Nonnull changed) CF_RETURNS_RETAINED;
int CinevaFFmpegSessionExternalSubtitle(CinevaFFmpegSession * _Nonnull session,
    const uint8_t * _Nonnull data, int length, const char * _Nonnull format);
int CinevaFFmpegSessionAudioTrackCount(CinevaFFmpegSession * _Nonnull session);
int CinevaFFmpegSessionAudioTrack(CinevaFFmpegSession * _Nonnull session, int ordinal, CinevaFFmpegAudioTrack * _Nonnull track);
int CinevaFFmpegSessionSelectAudio(CinevaFFmpegSession * _Nonnull session, int streamIndex);
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
/// Suspends only preview I/O timeout accounting. The caller gates preview AVIO
/// reads; cancellation and generation changes remain effective while inactive.
void CinevaFFmpegSessionSetPreviewIOActive(CinevaFFmpegSession * _Nonnull session, int active);
void CinevaFFmpegSessionSetVideoActive(CinevaFFmpegSession * _Nonnull session, int active);
void CinevaFFmpegSessionSnapshot(CinevaFFmpegSession * _Nonnull session,
    CinevaFFmpegSnapshot * _Nonnull snapshot);
CVPixelBufferRef _Nullable CinevaFFmpegSessionCopyFrame(CinevaFFmpegSession * _Nonnull session,
    double * _Nonnull pts, double * _Nonnull duration, int * _Nonnull serial) CF_RETURNS_RETAINED;
// Stereo interleaved Float32, 48000 Hz. Return valid frame count (not float count).
// Output memory is owned by the caller; each result includes media PTS/generation.
int CinevaFFmpegSessionCopyAudio(CinevaFFmpegSession * _Nonnull session,
    float * _Nonnull samples, int frameCapacity, double * _Nonnull pts, int * _Nonnull serial);
const char * _Nonnull CinevaFFmpegCodecName(int codec);
void CinevaFFmpegErrorText(int code, char * _Nonnull buffer, int capacity);

#ifdef __cplusplus
}
#endif
#endif
