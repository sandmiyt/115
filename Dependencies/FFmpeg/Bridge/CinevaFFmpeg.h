#ifndef CINEVA_FFMPEG_H
#define CINEVA_FFMPEG_H

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

#ifdef __cplusplus
}
#endif
#endif
