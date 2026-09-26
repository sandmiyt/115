#ifndef CINEVA_VIDEO_OUTPUT_H
#define CINEVA_VIDEO_OUTPUT_H
#include "CinevaFFmpeg.h"
#include <libavcodec/codec_par.h>
#include <libavutil/frame.h>
#include <libswscale/swscale.h>
// Internal, hidden ABI: returns an owned CoreVideo surface, never UIImage.
int cineva_copy_video_surface(AVFrame *frame, const AVCodecParameters *parameters,
    struct SwsContext **scale, CVPixelBufferRef *output, CinevaFFmpegSnapshot *info);
#endif
