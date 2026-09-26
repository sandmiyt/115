import AVFoundation
import UIKit

/// Uncompressed CVPixelBuffer output. The host timebase schedules presentation;
/// the display link only supplies frames. No UIImage, RGB copy or AVPlayer.
@MainActor
final class NativeVideoRenderer {
  enum Submission { case accepted, waiting, dropped, failed(String) }
  let layer = AVSampleBufferDisplayLayer()
  private var output: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }
  private var timebase: CMTimebase?
  private var format: CMVideoFormatDescription?
  private var blockedSince: Double?
  private(set) var anchored = false
  private(set) var waitingForData = false
  private(set) var lastPTS = -1.0
  private(set) var lastEnd = -1.0
  private(set) var submittedFrames = 0
  private(set) var droppedFrames = 0
  private(set) var recoveryCount = 0
  private(set) var waitReason = "等待首帧"
  var time: Double { timebase.map { CMTimebaseGetTime($0).seconds } ?? 0 }
  var available: Bool { timebase != nil }

  init() {
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = UIColor.black.cgColor
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
    layer.controlTimebase = timebase
    setRate(0)
  }

  func reset(to seconds: Double, newSession: Bool = false) {
    setRate(0)
    setTime(seconds)
    // Seek/stop explicitly remove the old image. Recovery below preserves it.
    layer.flushAndRemoveImage()
    format = nil
    anchored = false
    waitingForData = false
    blockedSince = nil
    lastPTS = -1
    lastEnd = -1
    waitReason = "等待首帧"
    if newSession { submittedFrames = 0; droppedFrames = 0; recoveryCount = 0 }
  }

  func setPlaying(_ playing: Bool) {
    setRate(playing && anchored && !waitingForData ? 1 : 0)
  }

  func suspendForData() {
    guard anchored, !waitingForData else { return }
    setRate(0)
    waitingForData = true
    waitReason = "等待下一帧"
  }

  /// At most two recoveries per session: an unsupported surface must produce a
  /// visible error, not an endless flush/retry loop that looks like buffering.
  private func recover() -> Bool {
    guard recoveryCount < 2 else { return false }
    recoveryCount += 1
    output.flush()
    format = nil
    blockedSince = nil
    anchored = false
    waitingForData = true
    lastPTS = -1
    lastEnd = -1
    return true
  }

  func submit(_ pixel: CVPixelBuffer, pts: Double, duration: Double,
              playing: Bool, now: Double) -> Submission {
    guard pts.isFinite else { droppedFrames += 1; return .dropped }
    if output.status == .failed || output.requiresFlushToResumeDecoding {
      let code = (output.error as NSError?)?.code ?? 0
      guard recover() else { return .failed("原生显示恢复失败（\(code)）。请返回原播放器。") }
    }
    // Resume the clock BEFORE checking readiness. Otherwise a full native queue
    // can wait for a paused clock while the producer waits for queue readiness.
    let restarting = !anchored || waitingForData
    if restarting {
      setTime(pts)
      setRate(playing ? 1 : 0)
    } else {
      if !playing { return .waiting }
      if pts <= lastPTS || pts + duration < time - 0.1 {
        droppedFrames += 1
        return .dropped
      }
      if pts > time + 0.15 { blockedSince = nil; waitReason = "按时间戳等待显示"; return .waiting }
    }
    guard output.isReadyForMoreMediaData else {
      waitReason = "等待原生显示层"
      if blockedSince == nil { blockedSince = now }
      // Ordinary look-ahead/paused queues are not failures. Only recover when
      // queued presentation deadlines have passed and output remains blocked.
      if now - (blockedSince ?? now) >= 1.5, restarting || time > lastEnd + 0.25 {
        guard recover() else { return .failed("原生显示层持续阻塞。请返回原播放器，并记录解码与显示计数。") }
      }
      return .waiting
    }
    blockedSince = nil
    let formatMatches = format.map { CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixel) } ?? false
    if !formatMatches {
      var description: CMVideoFormatDescription?
      guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixel, formatDescriptionOut: &description) == noErr, let description else {
        return .failed("无法建立视频帧格式。")
      }
      // Reuse only while dimensions, pixel format AND propagated color/HDR
      // attachments match. Dynamic format changes must not reuse SDR metadata.
      format = description
    }
    guard let format else { return .failed("视频帧格式不可用。") }
    var timing = CMSampleTimingInfo(
      duration: CMTime(seconds: duration, preferredTimescale: 60000),
      presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample) == noErr, let sample else { return .failed("无法建立显示采样。") }
    if restarting, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    output.enqueue(sample)
    anchored = true
    waitingForData = false
    lastPTS = pts
    lastEnd = pts + duration
    submittedFrames += 1
    waitReason = playing ? "按时间戳显示" : "已暂停"
    return .accepted
  }

  private func setTime(_ seconds: Double) {
    if let timebase { CMTimebaseSetTime(timebase, time: CMTime(seconds: seconds, preferredTimescale: 60000)) }
  }
  private func setRate(_ rate: Double) {
    if let timebase { CMTimebaseSetRate(timebase, rate: rate) }
  }
}
