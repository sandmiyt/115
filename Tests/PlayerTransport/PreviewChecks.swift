import AVFoundation
import CinevaFFmpeg
import Foundation
import CoreImage

@main struct PreviewChecks {
  static func main() async {
    setbuf(stdout,nil)
    let base=CommandLine.arguments[1]
    let originVideoOffset=Double(CommandLine.arguments[2])!
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
        if file=="rotated.mp4" {
          expect(image.height>image.width,"Display rotation applies to preview pixels")
          // Apple is an orientation oracle for this MP4 test ONLY; production
          // preview and every other fixture still use the real FFmpeg worker.
          let oracle=AVAssetImageGenerator(asset:AVURLAsset(url:source.url))
          oracle.appliesPreferredTrackTransform=true
          oracle.requestedTimeToleranceBefore = .zero; oracle.requestedTimeToleranceAfter = .zero
          // Query INSIDE the known interval: converting 2.583333333333333
          // to CMTime at a boundary can round down into the preceding frame.
          let oracleTime=frame.pts+abs(frame.duration)*0.25
          let reference=try! await oracle.image(at:CMTime(seconds:oracleTime,preferredTimescale:60000))
          expect(abs(reference.actualTime.seconds-frame.pts)<0.002,"Orientation oracle uses the same actual frame: expected=\(frame.pts), got=\(reference.actualTime.seconds)")
          let normalized=CIContext().createCGImage(CIImage(cgImage:reference.image),from:CGRect(x:0,y:0,width:CGFloat(reference.image.width),height:CGFloat(reference.image.height)),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)!
          expect(image.width==normalized.width && image.height==normalized.height,"Rotated bounds match track transform")
          let rawA=image.dataProvider!.data!, rawB=normalized.dataProvider!.data!
          let a=CFDataGetBytePtr(rawA)!, b=CFDataGetBytePtr(rawB)!
          var same=0,total=0
          for y in stride(from:2,to:image.height,by:3) { for x in stride(from:2,to:image.width,by:3) {
            if (a[y*image.bytesPerRow+x*4]>128)==(b[y*normalized.bytesPerRow+x*4]>128) { same+=1 }; total+=1
          } }
          withExtendedLifetime((rawA,rawB)) {}
          expect(Double(same)/Double(total)>0.98,"Preview orientation matches preferred track transform: \(same)/\(total) samples")
        }
        expect(max(image.width,image.height)<=481,"Preview output size bounded independently of source")
        if file != "rotated.mp4" && file != "4k.mp4", let raw=image.dataProvider?.data {
          let bytes=CFDataGetBytePtr(raw)!
          func number(_ y:Int) -> Int {
            (0..<8).reduce(0) { $0 | (bytes[y*image.bytesPerRow+(30+$1*32)*4]>128 ? (1 << $1) : 0) }
          }
          let videoOffset=file=="origin.mp4" ? originVideoOffset : 0
          let expected=Int(((frame.pts-videoOffset)*24).rounded())
          expect(number(130)==expected || number(image.height-1-130)==expected,"Decoded pixels carry the actual source frame number: \(file) pts=\(frame.pts) offset=\(videoOffset) expected=\(expected), got=\(number(130))/\(number(image.height-1-130)); never relabel target as PTS")
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
        let count=CinevaFFmpegSessionCopyAudio(primary.pointer,&pcm,65536,&pts,&serial)
        if count>0 { audio = audio || pcm.prefix(Int(count)*2).contains { abs($0)>0.00001 } }
        CinevaFFmpegSessionSnapshot(primary.pointer,&snapshot)
        expect(snapshot.status>=0,"Primary decoder survives preview lifetime")
        try? await Task.sleep(for:.milliseconds(10))
      }
      expect(video && (audio || file=="noaudio.mp4"),"Primary demux/video/PCM preserved; this does NOT prove audible iPhone output")
      if file=="subtitles.mkv" { expect(CinevaFFmpegSessionSubtitleTrackCount(primary.pointer)>0,"Subtitle enumeration survives preview isolation") }
      if file=="bframes.mp4" {
        let localRoot=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:localRoot) }
        let disk=SegmentDiskCache(root:localRoot)
        let identity=RangeCacheIdentity(account:"offline-fixture",fileID:file,size:io.fileSize,
          validator:"sha1:"+String(repeating:"c",count:40))
        let fill=RangeCoordinator(source:source,identity:identity,disk:disk)
        var probe=[UInt8](repeating:0,count:4096)
        expect(fill.read(offset:0,buffer:&probe,count:probe.count,generation:1)>0,"Offline fixture begins incrementally")
        fill.allowPrefetch(true)
        for _ in 0..<300 where !fill.mediaCacheProgress.complete { try? await Task.sleep(for:.milliseconds(50)) }
        expect(fill.mediaCacheProgress.complete,"Independent fixture fill reaches all media bytes")
        fill.close(); disk.flush()
        for target in [0.0,3.0,5.3] {
          let offlineSource=VideoSource(id:file,title:file,definition:0,
            url:URL(string:"cineva-cache://media/offline")!,kind:.original,headers:[:])
          let local=RangeCoordinator(source:offlineSource,identity:identity,disk:SegmentDiskCache(root:localRoot))
          var localOptions=CinevaFFmpegSessionOptions(); localOptions.outputAudio=1; localOptions.attach(local)
          let localPointer=offlineSource.url.absoluteString.withCString { CinevaFFmpegSessionCreate($0,"",target,localOptions) }!
          let localHandle=FFmpegSessionHandle(localPointer,io:local)
          var gotVideo=false,gotPCM=false
          let limit=ProcessInfo.processInfo.systemUptime+10
          while ProcessInfo.processInfo.systemUptime<limit && (!gotVideo || !gotPCM) {
            var pts=0.0,frameDuration=0.0,serial:Int32=0
            if CinevaFFmpegSessionCopyFrame(localHandle.pointer,&pts,&frameDuration,&serial) != nil { gotVideo=true }
            var pcm=[Float](repeating:0,count:131072)
            let count=CinevaFFmpegSessionCopyAudio(localHandle.pointer,&pcm,65536,&pts,&serial)
            if count>0 { gotPCM = gotPCM || pcm.prefix(Int(count)*2).contains { abs($0)>0.00001 } }
            try? await Task.sleep(for:.milliseconds(10))
          }
          expect(gotVideo && gotPCM,"Offline FFmpeg head/middle/tail video and non-silent PCM at \(target)")
          expect(local.statistics.requests==0,"Offline native session makes zero HTTP requests")
          local.close()
        }
      }
      io.close()
    }
    print("Native FFmpeg preview checks passed: \(checks); simulator fixture decoding only, NOT physical-device performance")
  }
}
