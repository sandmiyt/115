import AVFoundation
import CinevaFFmpeg
import CoreImage
import UIKit

/// A serial worker owns a reusable, silent demux/decoder. Primary A/V never
/// enters this object. Its cache dies with the source/representation session.
actor FFmpegPreviewWorker {
  struct Result: @unchecked Sendable {
    let image:UIImage?
    let pts:Double
    let duration:Double
    let note:String
    let milliseconds:Double
  }
  private struct Frame {
    let image:UIImage, pts:Double, duration:Double, track:Int32
    var bytes:Int { (image.cgImage?.bytesPerRow ?? 0)*(image.cgImage?.height ?? 0) }
  }
  private let source:VideoSource
  private let coordinator:RangeCoordinator?
  private var reader:FFmpegPreviewReader?
  private let context=CIContext(options:[.cacheIntermediates:false])
  private var handle:FFmpegSessionHandle?
  private var serial:Int32=1
  private var cursor = -1.0
  private var frames:[Frame]=[] // actual frame intervals; LRU <= 12 MiB / 64 frames
  private var ended=false
  init(source:VideoSource,coordinator:RangeCoordinator?) {
    self.source=source; self.coordinator=coordinator
  }
  // Can be called during an awaited read: native cancellation wakes its scoped
  // condition. Destruction/join is dispatched off MainActor by the handle.
  func close() { ended=true; handle=nil; reader?.cancel(-1); frames=[]; context.clearCaches() }

  func frame(at target:Double) async -> Result {
    let began=ProcessInfo.processInfo.systemUptime
    func result(_ f:Frame?,_ note:String) -> Result {
      Result(image:f?.image,pts:f?.pts ?? target,duration:f?.duration ?? 0,note:note,
             milliseconds:(ProcessInfo.processInfo.systemUptime-began)*1000)
    }
    guard !ended, !Task.isCancelled else { return result(nil,"已取消") }
    if let index=frames.firstIndex(where:{ target >= $0.pts && target < $0.pts+$0.duration }) {
      let hit=frames.remove(at:index); frames.append(hit); return result(hit,"帧缓存")
    }
    if handle==nil {
      var options=CinevaFFmpegSessionOptions()
      options.preferHardware=1; options.videoOnly=1; options.sequentialVideoOnly=1; options.preview=1
      reader=coordinator.map(FFmpegPreviewReader.init)
      if let reader { options.attachPreview(reader) }
      let headers=source.headers.sorted { $0.key<$1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
      let pointer=source.url.absoluteString.withCString { url in headers.withCString {
        CinevaFFmpegSessionCreate(url,$0,target,options)
      } }
      guard let pointer else { return result(nil,"无法创建预览") }
      handle=FFmpegSessionHandle(pointer,previewReader:reader); cursor=target; serial=1
    } else if target<cursor || target-cursor>3 {
      serial=CinevaFFmpegSessionSeek(handle!.pointer,target); cursor=target
    }
    guard let handle else { return result(nil,"已取消") }
    // Reuse queued frames and decode forward for nearby targets. A long GOP may
    // need more work, but never monopolizes the worker or resets the main engine.
    while !ended && !Task.isCancelled && ProcessInfo.processInfo.systemUptime-began<5 {
      var snapshot=CinevaFFmpegSnapshot(); CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot)
      if snapshot.status<0 { self.handle=nil; return result(nil,"预览读取失败（\(snapshot.errorCode)），播放不受影响") }
      var pts=0.0,duration=0.0,generation:Int32=0
      if let pixel=CinevaFFmpegSessionCopyFrame(handle.pointer,&pts,&duration,&generation) {
        guard generation==serial else { continue }
        cursor=pts+abs(duration)
        if cursor<=target { continue }
        var image=CIImage(cvPixelBuffer:pixel)
        if [16,18].contains(snapshot.colorTransfer) {
          if #available(iOS 18.0,*), image.contentHeadroom>1,
             let filter=CIFilter(name:"CIToneMapHeadroom") {
            filter.setValue(image,forKey:kCIInputImageKey); filter.setValue(1.0,forKey:"inputTargetHeadroom")
            guard let mapped=filter.outputImage else { return result(nil,"HDR 预览转换不可用") }; image=mapped
          } else { return result(nil,"此 HDR 预览需可靠的 SDR 映射；保留主画面") }
        }
        image=image.transformed(by:CGAffineTransform(rotationAngle:CGFloat(snapshot.rotation * .pi/180)))
        let scale=min(1,480/max(image.extent.width,image.extent.height))
        image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg=context.createCGImage(image,from:image.extent,format:.RGBA8,
          colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { return result(nil,"预览图像不可用") }
        let frame=Frame(image:UIImage(cgImage:cg),pts:pts,duration:duration,track:snapshot.videoStreamIndex)
        frames.removeAll { $0.pts==pts && $0.track==frame.track }; frames.append(frame)
        while frames.count>64 || frames.reduce(0,{ $0+$1.bytes })>12*1024*1024 { frames.removeFirst() }
        return result(frame,duration>0 && pts<=target && target<pts+duration ? "帧区间" : "近似帧（duration 缺失或目标间隙；实际 PTS）")
      }
      if snapshot.status==2 { return result(frames.last,"片尾最近帧") }
      do { try await Task.sleep(for:.milliseconds(8)) } catch { return result(nil,"已取消") }
    }
    return result(nil,"预览暂未就绪")
  }
}

/// MainActor merges the latest target while one worker request progresses. It
/// does not repeatedly cancel a cold read, which would starve first preview.
@MainActor
final class FFmpegTimelinePreview {
  let display=TimelinePreviewController()
  private var worker:FFmpegPreviewWorker?
  private var task:Task<Void,Never>?
  private var epoch=UUID()
  private var latest=0.0
  private var source:VideoSource?
  private var coordinator:RangeCoordinator?
  private(set) var diagnostic="预览尚未请求"
  func configure(source:VideoSource,coordinator:RangeCoordinator?) {
    stop(); self.source=source; self.coordinator=coordinator
  }
  func begin(at time:Double) {
    display.beginExternal(at:time)
    if worker==nil, let source { worker=FFmpegPreviewWorker(source:source,coordinator:coordinator) }
    update(time)
  }
  func update(_ time:Double) {
    guard time.isFinite, display.isActive else { return }
    latest=max(0,time); display.targetExternal(latest)
    guard task==nil, let worker else { return }
    let expected=epoch
    task=Task { [weak self] in
      while let self, !Task.isCancelled, self.epoch==expected {
        let target=self.latest
        let result=await worker.frame(at:target)
        guard !Task.isCancelled, self.epoch==expected else { return }
        if self.latest==target {
          self.display.displayExternal(result.image,pts:result.pts,note:result.note)
          self.diagnostic=String(format:"预览响应 %.1f ms · 目标 %@ · 实际 PTS %@ · 误差 %.3f s · %@",
            result.milliseconds,PlaybackPolicy.timestamp(target),PlaybackPolicy.timestamp(result.pts),
            result.pts-target,result.note)
          self.task=nil; return
        }
        do { try await Task.sleep(for:.milliseconds(60)) } catch { return }
      }
    }
  }
  func finish(keepOverlay:Bool) {
    epoch=UUID(); task?.cancel(); task=nil
    let previous=worker; worker=nil
    Task { await previous?.close() }
    display.end(keepImageUntilSeekCompletes:keepOverlay)
  }
  func stop() { finish(keepOverlay:false); source=nil; coordinator=nil; display.reset() }
}
