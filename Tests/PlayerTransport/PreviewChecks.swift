import AVFoundation
import CinevaFFmpeg
import Foundation

@main struct PreviewChecks {
  static func main() async {
    setbuf(stdout,nil)
    let base=CommandLine.arguments[1]
    var checks=0
    func expect(_ ok:Bool,_ text:String) { precondition(ok,text); checks+=1 }
    for file in ["bframes.mp4","longgop.mkv","hevc.mp4","fractional.mp4","vfr.mp4","noaudio.mp4","rotated.mp4","origin.mp4","subtitles.mkv","4k.mp4"] {
      let source=VideoSource(id:file,title:file,definition:0,url:URL(string:base+"/media/"+file)!,kind:.original,headers:[:])
      let io=RangeCoordinator(source:source,identity:RangeCacheIdentity(account:"test",fileID:file,size:0,validator:"generated-fixture"))
      let worker=FFmpegPreviewWorker(source:source,coordinator:io)
      for target in [2.517,2.601,4.731,0.517,5.999] {
        let frame=await worker.frame(at:target)
        expect(frame.image != nil,"Cold remote FFmpeg extraction: \(file) at \(target): \(frame.note)")
        expect(frame.pts.isFinite && abs(frame.pts-target)<0.12,"Real PTS must bracket or explicitly approximate target")
        if frame.duration>0 && frame.note=="帧区间" {
          expect(frame.pts<=target && target<frame.pts+frame.duration,"Frame interval contains target (B-frame/VFR aware)")
          let cached=await worker.frame(at:target)
          expect(cached.pts==frame.pts && cached.note=="帧缓存","Cache keys actual interval, not half-second bucket")
        }
        let image=frame.image!.cgImage!
        if file=="rotated.mp4" { expect(image.height>image.width,"Display rotation applies to preview pixels") }
        expect(max(image.width,image.height)<=481,"Preview output size bounded independently of source")
        if file != "rotated.mp4" && file != "4k.mp4", let raw=image.dataProvider?.data {
          let bytes=CFDataGetBytePtr(raw)!
          func number(_ y:Int) -> Int {
            (0..<8).reduce(0) { $0 | (bytes[y*image.bytesPerRow+(30+$1*32)*4]>128 ? (1 << $1) : 0) }
          }
          let expected=Int((frame.pts*24).rounded())
          expect(number(130)==expected || number(image.height-1-130)==expected,"Decoded pixels carry the actual source frame number; never relabel target as PTS")
        }
        print("Preview fixture \(file): target=\(target) pts=\(frame.pts) duration=\(frame.duration) \(frame.note)")
      }
      await worker.close()
      expect(io.statistics.terminalFailure==nil,"Preview close does not terminate primary transport")
      // The SAME coordinator still supports an audio-enabled production C session.
      var options=CinevaFFmpegSessionOptions(); options.outputAudio=1; options.preferHardware=1; options.attach(io)
      let pointer=source.url.absoluteString.withCString { CinevaFFmpegSessionCreate($0,"",2.0,options) }!
      let primary=FFmpegSessionHandle(pointer,io:io)
      var video=false, audio=false, snapshot=CinevaFFmpegSnapshot()
      let deadline=ProcessInfo.processInfo.systemUptime+10
      while ProcessInfo.processInfo.systemUptime<deadline && (!video || (!audio && file != "noaudio.mp4")) {
        var pts=0.0,duration=0.0,serial:Int32=0
        if CinevaFFmpegSessionCopyFrame(primary.pointer,&pts,&duration,&serial) != nil { video=true }
        var pcm=[Float](repeating:0,count:131072)
        if CinevaFFmpegSessionCopyAudio(primary.pointer,&pcm,65536,&pts,&serial)>0 { audio=true }
        CinevaFFmpegSessionSnapshot(primary.pointer,&snapshot)
        expect(snapshot.status>=0,"Primary decoder survives preview lifetime")
        try? await Task.sleep(for:.milliseconds(10))
      }
      expect(video && (audio || file=="noaudio.mp4"),"Primary demux/video/PCM preserved; this does NOT prove audible iPhone output")
      if file=="subtitles.mkv" { expect(CinevaFFmpegSessionSubtitleTrackCount(primary.pointer)>0,"Subtitle enumeration survives preview isolation") }
      io.close()
    }
    print("Native FFmpeg preview checks passed: \(checks); simulator fixture decoding only, NOT physical-device performance")
  }
}
