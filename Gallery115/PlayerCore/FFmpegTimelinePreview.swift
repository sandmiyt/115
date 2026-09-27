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
  private lazy var context=CIContext(options:[.cacheIntermediates:false])
  private var handle:FFmpegSessionHandle?
  private var serial:Int32=1
  private var cursor = -1.0
  private var frames:[Frame]=[] // actual frame intervals; LRU <= 12 MiB / 64 frames
  private var ended=false
  private var operation=0
  private(set) var sessionOpenCount=0
  init(source:VideoSource,coordinator:RangeCoordinator?) {
    self.source=source; self.coordinator=coordinator
  }
  // Can be called during an awaited read: native cancellation wakes its scoped
  // condition. Destruction/join is dispatched off MainActor by the handle.
  func suspend() {
    operation &+= 1
    if let handle { CinevaFFmpegSessionCancel(handle.pointer) }
    handle=nil; reader?.cancel(-1); reader=nil
  }
  func close() { ended=true; suspend(); frames=[]; context.clearCaches() }

  func frame(at target:Double) async -> Result {
    operation &+= 1
    let expectedOperation=operation
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
      sessionOpenCount+=1
    } else if target<cursor || target-cursor>3 {
      serial=CinevaFFmpegSessionSeek(handle!.pointer,target); cursor=target
    }
    guard let handle else { return result(nil,"已取消") }
    var tailFallback=false
    // Reuse queued frames and decode forward for nearby targets. A long GOP may
    // need more work, but never monopolizes the worker or resets the main engine.
    while !ended && operation==expectedOperation && !Task.isCancelled && ProcessInfo.processInfo.systemUptime-began<5 {
      var snapshot=CinevaFFmpegSnapshot(); CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot)
      if snapshot.serial != serial { serial=snapshot.serial; cursor=snapshot.recoveryTarget }
      if snapshot.status<0 { self.handle=nil; return result(nil,"预览读取失败（\(snapshot.errorCode)），播放不受影响") }
      var pts=0.0,duration=0.0,generation:Int32=0
      if let pixel=CinevaFFmpegSessionCopyFrame(handle.pointer,&pts,&duration,&generation) {
        // The first frame may arrive between the earlier snapshot and dequeue.
        CinevaFFmpegSessionSnapshot(handle.pointer,&snapshot)
        serial=snapshot.serial
        guard generation==serial else { continue }
        cursor=pts+abs(duration)
        if cursor<=target && !tailFallback { continue }
        var image=CIImage(cvPixelBuffer:pixel)
        if [16,18].contains(snapshot.colorTransfer) {
          if #available(iOS 18.0,*), image.contentHeadroom>1,
             let filter=CIFilter(name:"CIToneMapHeadroom") {
            filter.setValue(image,forKey:kCIInputImageKey); filter.setValue(1.0,forKey:"inputTargetHeadroom")
            guard let mapped=filter.outputImage else { return result(nil,"HDR 预览转换不可用") }; image=mapped
          } else { return result(nil,"此 HDR 预览需可靠的 SDR 映射；保留主画面") }
        }
        // Core Image uses a bottom-left coordinate system, whereas the
        // primary CALayer uses UIKit coordinates. Invert the layer angle.
        let angle=snapshot.rotation.isFinite ? snapshot.rotation.truncatingRemainder(dividingBy:360) : 0
        let quarter=(angle/90).rounded()
        if abs(angle/90-quarter)<0.0001 {
          // Exact EXIF transforms avoid an extra border pixel from cos(pi/2).
          let orientations:[Int32]=[1,6,3,8]
          image=image.oriented(forExifOrientation:orientations[(Int(quarter)%4+4)%4])
        } else { image=image.transformed(by:CGAffineTransform(rotationAngle:-CGFloat(angle * .pi/180))) }
        let scale=min(1,480/max(image.extent.width,image.extent.height))
        image=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg=context.createCGImage(image,from:image.extent,format:.RGBA8,
          colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { return result(nil,"预览图像不可用") }
        let frame=Frame(image:UIImage(cgImage:cg),pts:pts,duration:duration,track:snapshot.videoStreamIndex)
        frames.removeAll { $0.pts==pts && $0.track==frame.track }; frames.append(frame)
        while frames.count>64 || frames.reduce(0,{ $0+$1.bytes })>12*1024*1024 { frames.removeFirst() }
        return result(frame,duration>0 && pts<=target && target<pts+duration ? "帧区间" : "近似帧（duration 缺失或目标间隙；实际 PTS）")
      }
      if snapshot.status==2 {
        if !tailFallback, target>0 {
          // Some containers end audio after the final video interval. One
          // bounded nearby keyframe lookup, never a rewind/download from zero.
          tailFallback=true; serial=CinevaFFmpegSessionSeek(handle.pointer,max(0,target-0.1)); continue
        }
        return result(frames.min(by:{ abs($0.pts-target)<abs($1.pts-target) }),"片尾最近帧（非精确区间）")
      }
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
  private var direction=0
  private var directionEpoch=0
  private var source:VideoSource?
  private var coordinator:RangeCoordinator?
  private(set) var diagnostic="预览尚未请求"
  func configure(source:VideoSource,coordinator:RangeCoordinator?) {
    stop(); self.source=source; self.coordinator=coordinator
  }
  func begin(at time:Double) {
    epoch=UUID(); task?.cancel(); task=nil; direction=0; latest=time
    display.beginExternal(at:time)
    if worker==nil, let source { worker=FFmpegPreviewWorker(source:source,coordinator:coordinator) }
    update(time)
  }
  func update(_ time:Double) {
    guard time.isFinite, display.isActive else { return }
    let next=max(0,time), delta=next-latest
    if abs(delta)>0.001 {
      let nextDirection=delta>0 ? 1 : -1
      if direction != 0 && direction != nextDirection { directionEpoch &+= 1 }
      direction=nextDirection
    }
    latest=next; display.targetExternal(latest)
    guard task==nil, let worker else { return }
    let expected=epoch
    task=Task { [weak self] in
      while let self, !Task.isCancelled, self.epoch==expected {
        let target=self.latest
        let motion=self.directionEpoch
        let result=await worker.frame(at:target)
        guard !Task.isCancelled, self.epoch==expected else { return }
        // One sampled frame in flight, one replaceable pending target. Requiring
        // equality with every touch event starves all output while dragging.
        // Never publish a result from an old drag or reversal. A slow GOP still
        // publishes its actual sampled PTS; an age cutoff would starve every
        // frame on slower devices. The next decode takes only the newest target.
        if self.latest==target || self.directionEpoch==motion {
          self.display.displayExternal(result.image,pts:result.pts,note:result.note)
          self.diagnostic=String(format:"预览取帧 %.1f ms · 采样目标 %@ · 实际 PTS %@ · 误差 %.3f s · %@",
            result.milliseconds,PlaybackPolicy.timestamp(target),PlaybackPolicy.timestamp(result.pts),
            result.pts-target,result.note)
        }
        if self.latest==target { self.task=nil; return }
        do { try await Task.sleep(for:.milliseconds(16)) } catch { return }
      }
    }
  }
  func finish(keepOverlay:Bool) {
    epoch=UUID(); task?.cancel(); task=nil
    // Keep the bounded decoder/index alive between gestures. An unawaited
    // suspend used to race the next begin and cancel its brand-new preview.
    display.end(keepImageUntilSeekCompletes:keepOverlay)
  }
  func stop() {
    finish(keepOverlay:false)
    let previous=worker; worker=nil; Task { await previous?.close() }
    source=nil; coordinator=nil; display.reset()
  }
}
