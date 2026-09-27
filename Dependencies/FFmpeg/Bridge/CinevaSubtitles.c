#include "CinevaSubtitles.h"
#include <libavcodec/avcodec.h>
#include <ass/ass.h>
#include <pthread.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Separate packet worker. Overflow disables only subtitles with a visible error;
// it never blocks the demuxer needed by starving audio/video tracks.
#define SUB_PACKETS 128
#define SUB_BYTES (2*1024*1024)
#define BITMAP_EVENTS 32
typedef struct { AVPacket *packet; int serial; } SubPacket;
typedef struct { AVSubtitle sub; double start,end; int64_t bytes; } BitmapEvent;
struct CinevaSubtitles {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    pthread_t worker;
    int started, stop, serial, selected, external, error;
    int count, head, queued;
    int64_t bytes, bitmapBytes;
    double origin, time;
    SubPacket packets[SUB_PACKETS];
    BitmapEvent bitmaps[BITMAP_EVENTS];
    int bitmapCount, dirty;
    AVCodecParameters *parameters[32];
    AVRational bases[32];
    CinevaFFmpegSubtitleTrack tracks[32];
    AVCodecContext *decoder;
    ASS_Library *library;
    ASS_Renderer *renderer;
    ASS_Track *track;
};
static const char *defaultHeader =
"[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n"
"[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
"Style: Default,Arial,42,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,30,30,30,1\n"
"[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n";
static void clearPackets(CinevaSubtitles *s) {
    for(int i=0;i<s->queued;i++) av_packet_free(&s->packets[(s->head+i)%SUB_PACKETS].packet);
    s->head=s->queued=0; s->bytes=0;
}
static void clearBitmap(CinevaSubtitles *s) {
    for(int i=0;i<s->bitmapCount;i++) avsubtitle_free(&s->bitmaps[i].sub);
    s->bitmapCount=0; s->bitmapBytes=0; s->dirty=1;
}
static void makeTrack(CinevaSubtitles *s, AVCodecContext *codec) {
    if(s->track) ass_free_track(s->track);
    s->track=ass_new_track(s->library);
    if(!s->track) return;
    if(codec && codec->subtitle_header_size>0)
        ass_process_codec_private(s->track,(char *)codec->subtitle_header,codec->subtitle_header_size);
    else ass_process_codec_private(s->track,(char *)defaultHeader,(int)strlen(defaultHeader));
    ass_configure_prune(s->track,120000);
    s->dirty=1;
}
static int openSelected(CinevaSubtitles *s) {
    avcodec_free_context(&s->decoder);
    if(s->selected<0) return 0;
    int n=-1;
    for(int i=0;i<s->count;i++) if(s->tracks[i].index==s->selected) n=i;
    if(n<0) return AVERROR_STREAM_NOT_FOUND;
    const AVCodec *codec=avcodec_find_decoder(s->parameters[n]->codec_id);
    if(!codec) return AVERROR_DECODER_NOT_FOUND;
    s->decoder=avcodec_alloc_context3(codec);
    if(!s->decoder) return AVERROR(ENOMEM);
    int result=avcodec_parameters_to_context(s->decoder,s->parameters[n]);
    s->decoder->pkt_timebase=s->bases[n];
    if(result>=0) result=avcodec_open2(s->decoder,codec,NULL);
    if(result>=0) makeTrack(s,s->decoder);
    return result;
}
static void pruneBitmaps(CinevaSubtitles *s,double time) {
    for(int i=0;i<s->bitmapCount;) {
        if(s->bitmaps[i].end>=time-1) { i++; continue; }
        s->bitmapBytes-=s->bitmaps[i].bytes;
        avsubtitle_free(&s->bitmaps[i].sub);
        memmove(s->bitmaps+i,s->bitmaps+i+1,(--s->bitmapCount-i)*sizeof(BitmapEvent));
        s->dirty=1;
    }
}
static void decode(CinevaSubtitles *s, AVPacket *packet) {
    AVSubtitle sub={0}; int got=0;
    int result=avcodec_decode_subtitle2(s->decoder,&sub,&got,packet);
    if(result<0) { s->error=result; return; }
    if(!got) return;
    double stamp=sub.pts!=AV_NOPTS_VALUE ? sub.pts/(double)AV_TIME_BASE :
        packet->pts!=AV_NOPTS_VALUE ? packet->pts*av_q2d(s->decoder->pkt_timebase) : s->time+s->origin;
    double start=stamp-s->origin+sub.start_display_time/1000.0;
    double end=stamp-s->origin+sub.end_display_time/1000.0;
    int bitmap=0; int64_t bytes=0;
    for(unsigned i=0;i<sub.num_rects;i++) {
        AVSubtitleRect *rect=sub.rects[i];
        if(rect->type==SUBTITLE_ASS && rect->ass && s->track) {
            double duration=end>start && end-start<86400 ? end-start :
                packet->duration>0 ? packet->duration*av_q2d(s->decoder->pkt_timebase) : 5;
            ass_process_chunk(s->track,rect->ass,(int)strlen(rect->ass),(long long)(start*1000),(long long)(duration*1000));
            s->dirty=1;
        } else if(rect->type==SUBTITLE_BITMAP) {
            bitmap=1; bytes+=(int64_t)rect->linesize[0]*rect->h+1024;
        }
    }
    if(bitmap || !sub.num_rects) {
        pruneBitmaps(s,s->time);
        // PGS commonly closes the previous display set with the next event.
        if(s->bitmapCount && s->bitmaps[s->bitmapCount-1].end>start)
            s->bitmaps[s->bitmapCount-1].end=start;
        if(s->bitmapCount>=BITMAP_EVENTS || bytes<0 || s->bitmapBytes+bytes>32*1024*1024) {
            s->error=AVERROR(ENOBUFS); avsubtitle_free(&sub); return;
        }
        s->bitmaps[s->bitmapCount++]=(BitmapEvent){sub,start,end>start ? end : INFINITY,bytes};
        s->bitmapBytes+=bytes; s->dirty=1;
    } else avsubtitle_free(&sub);
}
static void *worker(void *opaque) {
    CinevaSubtitles *s=opaque;
    pthread_mutex_lock(&s->lock);
    int active=-2;
    while(!s->stop) {
        while(!s->stop && !s->queued) pthread_cond_wait(&s->changed,&s->lock);
        if(s->stop) break;
        SubPacket item=s->packets[s->head]; s->head=(s->head+1)%SUB_PACKETS; s->queued--; s->bytes-=item.packet->size;
        if(item.serial==s->serial && !s->external) {
            if(active!=s->selected || !s->decoder) { s->error=openSelected(s); active=s->selected; }
            if(s->decoder && s->error>=0) decode(s,item.packet);
        }
        av_packet_free(&item.packet);
    }
    pthread_mutex_unlock(&s->lock); return NULL;
}
CinevaSubtitles *cineva_sub_create(AVFormatContext *format,double origin) {
    CinevaSubtitles *s=calloc(1,sizeof(*s)); if(!s) return NULL;
    pthread_mutex_init(&s->lock,NULL); pthread_cond_init(&s->changed,NULL);
    s->origin=origin; s->selected=-1; s->serial=1;
    s->library=ass_library_init();
    if(s->library) s->renderer=ass_renderer_init(s->library);
    if(!s->renderer) { cineva_sub_destroy(s); return NULL; }
    ass_set_frame_size(s->renderer,1280,720);
    ass_set_storage_size(s->renderer,1280,720);
    ass_set_cache_limits(s->renderer,1000,24);
    int64_t fontBytes=0;
    for(unsigned i=0;i<format->nb_streams;i++) {
        AVStream *st=format->streams[i];
        if(st->codecpar->codec_type==AVMEDIA_TYPE_ATTACHMENT && st->codecpar->extradata_size>0 && st->codecpar->extradata_size<=4*1024*1024) {
            AVDictionaryEntry *name=av_dict_get(st->metadata,"filename",NULL,0);
            if(name && fontBytes+st->codecpar->extradata_size<=16*1024*1024 &&
                (st->codecpar->codec_id==AV_CODEC_ID_TTF || st->codecpar->codec_id==AV_CODEC_ID_OTF)) {
                ass_add_font(s->library,name->value,(char *)st->codecpar->extradata,st->codecpar->extradata_size);
                fontBytes+=st->codecpar->extradata_size;
            }
        }
        if(st->codecpar->codec_type!=AVMEDIA_TYPE_SUBTITLE || s->count>=32 || !avcodec_find_decoder(st->codecpar->codec_id)) continue;
        int n=s->count;
        s->parameters[n]=avcodec_parameters_alloc();
        if(!s->parameters[n] || avcodec_parameters_copy(s->parameters[n],st->codecpar)<0) { avcodec_parameters_free(&s->parameters[n]); continue; }
        s->bases[n]=st->time_base;
        CinevaFFmpegSubtitleTrack *track=&s->tracks[n]; track->index=(int)i; track->codec=st->codecpar->codec_id;
        AVDictionaryEntry *lang=av_dict_get(st->metadata,"language",NULL,0),*title=av_dict_get(st->metadata,"title",NULL,0);
        snprintf(track->language,sizeof(track->language),"%s",lang?lang->value:"und");
        snprintf(track->title,sizeof(track->title),"%s",title?title->value:""); s->count++;
    }
    ass_set_fonts(s->renderer,NULL,"Arial",ASS_FONTPROVIDER_CORETEXT,NULL,1);
    makeTrack(s,NULL);
    if(pthread_create(&s->worker,NULL,worker,s)) { cineva_sub_destroy(s); return NULL; }
    s->started=1; return s;
}
void cineva_sub_destroy(CinevaSubtitles *s) {
    if(!s) return;
    pthread_mutex_lock(&s->lock); s->stop=1; pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->lock);
    if(s->started) pthread_join(s->worker,NULL);
    clearPackets(s); clearBitmap(s); avcodec_free_context(&s->decoder);
    for(int i=0;i<32;i++) avcodec_parameters_free(&s->parameters[i]);
    if(s->track) ass_free_track(s->track);
    if(s->renderer) ass_renderer_done(s->renderer);
    if(s->library) ass_library_done(s->library);
    pthread_cond_destroy(&s->changed); pthread_mutex_destroy(&s->lock); free(s);
}
void cineva_sub_reset(CinevaSubtitles *s,int serial) {
    if(!s) return;
    pthread_mutex_lock(&s->lock); s->serial=serial; clearPackets(s); clearBitmap(s);
    avcodec_free_context(&s->decoder);
    if(!s->external) makeTrack(s,NULL);
    s->dirty=1; pthread_mutex_unlock(&s->lock);
}
int cineva_sub_select(CinevaSubtitles *s,int index) {
    if(!s) return -1;
    pthread_mutex_lock(&s->lock);
    int found=index==-1;
    for(int i=0;i<s->count;i++) if(s->tracks[i].index==index) found=1;
    if(found) { s->selected=index; s->external=0; s->error=0; clearPackets(s); clearBitmap(s); avcodec_free_context(&s->decoder); makeTrack(s,NULL); }
    pthread_mutex_unlock(&s->lock); return found?0:-1;
}
int cineva_sub_index(CinevaSubtitles *s) { if(!s)return -1; pthread_mutex_lock(&s->lock); int n=s->selected; pthread_mutex_unlock(&s->lock); return n; }
int cineva_sub_count(CinevaSubtitles *s) { return s?s->count:0; }
int cineva_sub_track(CinevaSubtitles *s,int ordinal,CinevaFFmpegSubtitleTrack *track) {
    if(!s || ordinal<0 || ordinal>=s->count) return 0; *track=s->tracks[ordinal]; return 1;
}
int cineva_sub_error(CinevaSubtitles *s) { if(!s)return 0; pthread_mutex_lock(&s->lock); int e=s->error; pthread_mutex_unlock(&s->lock); return e; }
void cineva_sub_put(CinevaSubtitles *s,const AVPacket *packet,int serial) {
    if(!s)return;
    pthread_mutex_lock(&s->lock);
    if(serial==s->serial && packet->stream_index==s->selected && !s->external) {
        if(packet->size<0 || s->queued>=SUB_PACKETS || s->bytes+packet->size>SUB_BYTES) s->error=AVERROR(ENOBUFS);
        else {
            AVPacket *copy=av_packet_clone(packet);
            if(copy) { s->packets[(s->head+s->queued++)%SUB_PACKETS]=(SubPacket){copy,serial}; s->bytes+=copy->size; pthread_cond_signal(&s->changed); }
        }
    }
    pthread_mutex_unlock(&s->lock);
}
static void blend(uint8_t *dst,int r,int g,int b,int a) {
    int inverse=255-a;
    dst[0]=(uint8_t)((b*a+dst[0]*inverse+127)/255);
    dst[1]=(uint8_t)((g*a+dst[1]*inverse+127)/255);
    dst[2]=(uint8_t)((r*a+dst[2]*inverse+127)/255);
    dst[3]=(uint8_t)(a+(dst[3]*inverse+127)/255);
}
int cineva_sub_render(CinevaSubtitles *s,double time,int serial,CVPixelBufferRef *pixel) {
    *pixel=NULL; if(!s || !isfinite(time))return 0;
    pthread_mutex_lock(&s->lock);
    if(s->serial!=serial) { pthread_mutex_unlock(&s->lock); return 0; }
    s->time=time; pruneBitmaps(s,time);
    int changed=0;
    ASS_Image *images=s->track?ass_render_frame(s->renderer,s->track,(long long)(time*1000),&changed):NULL;
    // Bitmap events are cheap and may cross a display boundary without packets.
    if(!changed && !s->dirty && !s->bitmapCount) { pthread_mutex_unlock(&s->lock); return 0; }
    s->dirty=0;
    BitmapEvent *bitmap=NULL;
    for(int i=0;i<s->bitmapCount;i++) if(s->bitmaps[i].start<=time && time<s->bitmaps[i].end) bitmap=&s->bitmaps[i];
    if(!images && (!bitmap || !bitmap->sub.num_rects)) { pthread_mutex_unlock(&s->lock); return 1; }
    CVPixelBufferRef buffer=NULL;
    if(CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_32BGRA,NULL,&buffer)!=kCVReturnSuccess) { pthread_mutex_unlock(&s->lock); return 0; }
    CVPixelBufferLockBaseAddress(buffer,0);
    uint8_t *base=CVPixelBufferGetBaseAddress(buffer); size_t stride=CVPixelBufferGetBytesPerRow(buffer);
    memset(base,0,stride*720);
    for(ASS_Image *image=images;image;image=image->next) {
        int r=image->color>>24,g=(image->color>>16)&255,b=(image->color>>8)&255,alpha=255-(image->color&255);
        for(int y=0;y<image->h;y++) for(int x=0;x<image->w;x++) {
            int dx=image->dst_x+x,dy=image->dst_y+y;
            if(dx>=0 && dx<1280 && dy>=0 && dy<720) blend(base+dy*stride+dx*4,r,g,b,(image->bitmap[y*image->stride+x]*alpha+127)/255);
        }
    }
    if(bitmap && s->decoder) {
        double sx=1280.0/fmax(1,s->decoder->width),sy=720.0/fmax(1,s->decoder->height);
        for(unsigned i=0;i<bitmap->sub.num_rects;i++) {
            AVSubtitleRect *rect=bitmap->sub.rects[i];
            if(rect->type!=SUBTITLE_BITMAP || !rect->data[0] || !rect->data[1] || rect->w<=0 || rect->h<=0) continue;
            int left=fmax(0,floor(rect->x*sx)),top=fmax(0,floor(rect->y*sy));
            int right=fmin(1280,ceil((rect->x+rect->w)*sx)),bottom=fmin(720,ceil((rect->y+rect->h)*sy));
            for(int y=top;y<bottom;y++) for(int x=left;x<right;x++) {
                int px=fmin(rect->w-1,fmax(0,(int)(x/sx)-rect->x)),py=fmin(rect->h-1,fmax(0,(int)(y/sy)-rect->y));
                int index=rect->data[0][py*rect->linesize[0]+px];
                if(index>=rect->nb_colors) continue;
                uint32_t color=((uint32_t *)rect->data[1])[index];
                blend(base+y*stride+x*4,(color>>16)&255,(color>>8)&255,color&255,color>>24);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer,0); *pixel=buffer;
    pthread_mutex_unlock(&s->lock); return 1;
}
typedef struct { const uint8_t *data; int size,offset; } TextInput;
static int textRead(void *opaque,uint8_t *buffer,int count) {
    TextInput *input=opaque; int n=FFMIN(count,input->size-input->offset);
    if(n<=0)return AVERROR_EOF;
    memcpy(buffer,input->data+input->offset,n); input->offset+=n; return n;
}
int cineva_sub_external(CinevaSubtitles *s,const uint8_t *data,int size,const char *format) {
    if(!s || size<=0 || size>4*1024*1024)return AVERROR(EFBIG);
    pthread_mutex_lock(&s->lock);
    if(!strcmp(format,"srt") || !strcmp(format,"vtt")) {
        TextInput input={data,size,0};
        AVFormatContext *demux=avformat_alloc_context();
        uint8_t *bytes=av_malloc(32768);
        AVIOContext *io=bytes?avio_alloc_context(bytes,32768,0,&input,textRead,NULL,NULL):NULL;
        if(!demux || !io) {
            avformat_free_context(demux); av_free(bytes); pthread_mutex_unlock(&s->lock); return AVERROR(ENOMEM);
        }
        demux->pb=io; demux->flags|=AVFMT_FLAG_CUSTOM_IO;
        const AVInputFormat *type=av_find_input_format(!strcmp(format,"vtt")?"webvtt":"srt");
        int result=avformat_open_input(&demux,NULL,type,NULL);
        if(result>=0 && demux->nb_streams>0) {
            const AVCodec *codec=avcodec_find_decoder(demux->streams[0]->codecpar->codec_id);
            AVCodecContext *context=codec?avcodec_alloc_context3(codec):NULL;
            result=context?avcodec_parameters_to_context(context,demux->streams[0]->codecpar):AVERROR_DECODER_NOT_FOUND;
            if(context) context->pkt_timebase=demux->streams[0]->time_base;
            if(result>=0) result=avcodec_open2(context,codec,NULL);
            if(result>=0) {
                clearPackets(s); clearBitmap(s); avcodec_free_context(&s->decoder); s->decoder=context; context=NULL;
                s->selected=-1; s->external=1; s->error=0; makeTrack(s,s->decoder);
                if(s->track) ass_configure_prune(s->track,-1); // Whole sidecar remains available for backward seek.
                double origin=s->origin; s->origin=0;
                AVPacket *packet=av_packet_alloc(); int count=0;
                if(!packet) result=AVERROR(ENOMEM);
                else {
                    while((result=av_read_frame(demux,packet))>=0 && count++<20000) { decode(s,packet); av_packet_unref(packet); }
                    if(result==AVERROR_EOF) result=s->error;
                    if(count>=20000)result=AVERROR(EFBIG);
                }
                av_packet_free(&packet); s->origin=origin;
            }
            avcodec_free_context(&context);
        }
        avformat_close_input(&demux); av_freep(&io->buffer); avio_context_free(&io);
        pthread_mutex_unlock(&s->lock); return result;
    }
    if(strcmp(format,"ass") && strcmp(format,"ssa")) { pthread_mutex_unlock(&s->lock); return AVERROR(ENOSYS); }
    ASS_Track *track=ass_read_memory(s->library,(char *)data,size,"UTF-8");
    if(!track || track->n_events>20000) { if(track)ass_free_track(track); pthread_mutex_unlock(&s->lock); return AVERROR_INVALIDDATA; }
    clearPackets(s); clearBitmap(s); s->selected=-1; s->external=1;
    if(s->track)ass_free_track(s->track); s->track=track; s->dirty=1; s->error=0;
    pthread_mutex_unlock(&s->lock); return 0;
}
