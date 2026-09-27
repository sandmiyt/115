#ifndef CINEVA_SUBTITLES_H
#define CINEVA_SUBTITLES_H
#include "CinevaFFmpeg.h"
#include <libavformat/avformat.h>
typedef struct CinevaSubtitles CinevaSubtitles;
CinevaSubtitles *cineva_sub_create(AVFormatContext *format, double origin);
void cineva_sub_destroy(CinevaSubtitles *s);
void cineva_sub_reset(CinevaSubtitles *s, int serial);
int cineva_sub_index(CinevaSubtitles *s);
int cineva_sub_select(CinevaSubtitles *s, int index);
void cineva_sub_put(CinevaSubtitles *s, const AVPacket *packet, int serial);
int cineva_sub_count(CinevaSubtitles *s);
int cineva_sub_track(CinevaSubtitles *s, int ordinal, CinevaFFmpegSubtitleTrack *track);
int cineva_sub_render(CinevaSubtitles *s, double time, int serial, CVPixelBufferRef *pixel);
int cineva_sub_external(CinevaSubtitles *s, const uint8_t *data, int size, const char *format);
int cineva_sub_error(CinevaSubtitles *s);
#endif
