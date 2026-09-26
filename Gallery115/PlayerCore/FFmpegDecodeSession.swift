import AVFoundation
import CinevaFFmpeg
import Observation
import UIKit

/// Owns one native session. Cancellation is immediate; joining workers and
/// freeing FFmpeg objects never blocks SwiftUI or a display-link callback.
private final class FFmpegSessionHandle {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit {
    CinevaFFmpegSessionCancel(pointer)
    let address = UInt(bitPattern: pointer)
    DispatchQueue.global(qos: .utility).async {
      if let pointer = OpaquePointer(bitPattern: address) { CinevaFFmpegSessionDestroy(pointer) }
    }
  }
}

@MainActor
private final class DecodeDisplayLinkTarget: NSObject {
  weak var session: FFmpegDecodeSession?
  @objc func tick() { session?.pump() }
}

/// Phase 4 validation transport. Intentionally not a full PlayerEngine: audio,
/// rate stretching, track selection and PiP are not implemented by this path.
@MainActor @Observable
final class FFmpegDecodeSession {
  private(set) var state: PlayerState = .idle
  private(set) var currentTime = 0.0
  private(set) var duration = 0.0
  private(set) var videoFrames: Int64 = 0
  private(set) var audioFrames: Int64 = 0
  private(set) var packetBytes: Int64 = 0
  private(set) var frameCount = 0
  private(set) var mediaDescription = "正在读取媒体信息"
  private(set) var firstFrameSeconds: Double?
  private(set) var lastSeekSeconds: Double?
  private(set) var rotation = 0.0
  private(set) var wantsPlayback = true
  private(set) var decoderDescription = "等待实际解码帧"
  private(set) var outputDescription = "等待画面输出"
  private(set) var colorDescription = "等待色彩信息"
  private(set) var fallbackDescription: String?
  private(set) var hardwareFrames: Int64 = 0
  private(set) var softwareFrames: Int64 = 0
  let hdrDisplayEligible = AVPlayer.eligibleForHDRPlayback
  let displayLayer = AVSampleBufferDisplayLayer()

  @ObservationIgnored private var handle: FFmpegSessionHandle?
  @ObservationIgnored private var displayLink: CADisplayLink?
  @ObservationIgnored private var timebase: CMTimebase?
  @ObservationIgnored private var pending: (CVPixelBuffer, Double, Int32)?
  @ObservationIgnored private var serial: Int32 = 1
  @ObservationIgnored private var anchored = false
  @ObservationIgnored private var lastEnqueuedPTS = -1.0
  @ObservationIgnored private var startedAt = 0.0
  @ObservationIgnored private var seekStartedAt: Double?
  @ObservationIgnored private var lastPublishedAt = 0.0
  @ObservationIgnored private var frameStep = 1.0 / 30.0

  init() {
    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = UIColor.black.cgColor
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
    displayLayer.controlTimebase = timebase
    if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
  }

  func start(source: VideoSource, at seconds: Double, preferHardware: Bool = true) {
    guard handle == nil else { return }
    anchored = false
    serial = 1
    lastEnqueuedPTS = -1
    firstFrameSeconds = nil
    lastSeekSeconds = nil
    seekStartedAt = nil
    wantsPlayback = true
    decoderDescription = "等待实际解码帧"
    outputDescription = "等待画面输出"
    colorDescription = "等待色彩信息"
    fallbackDescription = nil
    hardwareFrames = 0
    softwareFrames = 0
    guard let scheme = source.url.scheme?.lowercased(), ["https", "http"].contains(scheme),
      let timebase else { state = .failed("验证入口仅支持 HTTP/HTTPS 视频地址。"); return }
    // Prevent header injection. Headers come from the existing provider, not UI.
    let validHeaders = source.headers.allSatisfy { key, value in
      !key.isEmpty && !key.contains(":") && !key.contains(where: { $0.isNewline }) &&
        !value.contains(where: { $0.isNewline })
    }
    guard validHeaders else { state = .failed("播放请求头格式无效。"); return }
    let headers = source.headers.sorted { $0.key < $1.key }
      .map { "\($0.key): \($0.value)\r\n" }.joined()
    let pointer = source.url.absoluteString.withCString { url in
      headers.withCString { CinevaFFmpegSessionCreate(url, $0, seconds, preferHardware ? 1 : 0) }
    }
    guard let pointer else { state = .failed("无法创建 FFmpeg 解码会话。"); return }
    handle = FFmpegSessionHandle(pointer)
    state = .preparing
    currentTime = max(0, seconds)
    CMTimebaseSetTime(timebase, time: CMTime(seconds: currentTime, preferredTimescale: 60000))
    startedAt = CACurrentMediaTime()
    let target = DecodeDisplayLinkTarget()
    target.session = self
    let link = CADisplayLink(target: target, selector: #selector(DecodeDisplayLinkTarget.tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    if let timebase { CMTimebaseSetRate(timebase, rate: 0) }
    pending = nil
    displayLayer.flushAndRemoveImage()
    handle = nil
    state = .stopped
  }

  func toggle() {
    if state == .ended { wantsPlayback = true; seek(to: 0); return }
    wantsPlayback.toggle()
    if let timebase { CMTimebaseSetRate(timebase, rate: wantsPlayback && anchored ? 1 : 0) }
    if anchored { state = wantsPlayback ? .playing : .paused }
  }

  func seek(to seconds: Double) {
    guard let handle, duration > 0, seconds.isFinite else { return }
    let target = min(max(0, seconds), max(0, duration - 0.1))
    serial = CinevaFFmpegSessionSeek(handle.pointer, target)
    pending = nil
    anchored = false
    lastEnqueuedPTS = -1
    currentTime = target
    seekStartedAt = CACurrentMediaTime()
    if let timebase {
      CMTimebaseSetRate(timebase, rate: 0)
      CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 60000))
    }
    displayLayer.flushAndRemoveImage()
    state = .seeking
  }

  fileprivate func pump() {
    guard let handle, let timebase else { return }
    var snapshot = CinevaFFmpegSnapshot()
    CinevaFFmpegSessionSnapshot(handle.pointer, &snapshot)
    if snapshot.status < 0 {
      let code = snapshot.errorCode
      stop()
      state = .failed(code == -70001
        ? "检测到 Dolby Vision，本阶段尚未接入其动态元数据处理。请返回原播放器使用系统内核。"
        : "FFmpeg 验证未能继续（\(code)）。可能是地址过期、网络超时或格式暂不支持。请返回原播放器。")
      return
    }
    // Decoder failure can trigger an internal keyframe restart in software.
    // Treat it exactly like a new seek; no old hardware frame may reappear.
    if snapshot.serial != serial {
      serial = snapshot.serial
      pending = nil
      anchored = false
      lastEnqueuedPTS = -1
      currentTime = snapshot.recoveryTarget
      CMTimebaseSetRate(timebase, rate: 0)
      CMTimebaseSetTime(timebase, time: CMTime(seconds: currentTime, preferredTimescale: 60000))
      displayLayer.flushAndRemoveImage()
      state = .seeking
    }
    if anchored { CinevaFFmpegSessionSetPosition(handle.pointer, CMTimebaseGetTime(timebase).seconds) }
    let now = CACurrentMediaTime()
    if now - lastPublishedAt >= 0.25 {
      lastPublishedAt = now
      duration = snapshot.duration
      videoFrames = snapshot.videoFrames
      audioFrames = snapshot.audioFrames
      packetBytes = snapshot.packetBytes
      frameCount = Int(snapshot.frameCount)
      hardwareFrames = snapshot.hardwareFrames
      softwareFrames = snapshot.softwareFrames
      decoderDescription = snapshot.decoderType == 2 ? "VideoToolbox 硬件解码" :
        (snapshot.decoderType == 1 ? "FFmpeg 软件解码" : "等待实际解码帧")
      if snapshot.outputWidth > 0 {
        outputDescription = "\(snapshot.outputWidth)×\(snapshot.outputHeight) · \(snapshot.outputBitDepth) 位 · 原生显示"
        let transfer = snapshot.colorTransfer == 16 ? "HDR10 / PQ" : (snapshot.colorTransfer == 18 ? "HLG" : "SDR / 非 PQ、HLG")
        colorDescription = "\(transfer) · primaries \(snapshot.colorPrimaries) / matrix \(snapshot.colorMatrix)"
          + " · MDCV \(snapshot.hasMastering == 1 ? "有" : "无") / CLL \(snapshot.hasContentLight == 1 ? "有" : "无")"
      }
      switch snapshot.fallbackReason {
      case 1: fallbackDescription = "当前设备或编码未提供可用硬解，使用软件解码。"
      case 2: fallbackDescription = "硬解设备初始化失败，已改用软件解码。"
      case 3: fallbackDescription = "硬解会话不接受当前格式或 Profile，已改用软件解码。"
      case 4: fallbackDescription = "硬解过程中失败，已从当前位置附近的关键帧重新软件解码。"
      case 5: fallbackDescription = "本次手动选择软件解码对照。"
      default: fallbackDescription = nil
      }
      rotation = snapshot.rotation.isFinite ? snapshot.rotation : 0
      if snapshot.status > 0 {
        let video = String(cString: CinevaFFmpegCodecName(snapshot.videoCodec))
        let audio = snapshot.audioCodec == 0 ? "无音轨" : String(cString: CinevaFFmpegCodecName(snapshot.audioCodec))
        mediaDescription = "\(video) · \(snapshot.width)×\(snapshot.height) · 音频 \(audio)"
        if snapshot.fps.isFinite, snapshot.fps > 0 { frameStep = 1 / snapshot.fps }
      }
      if anchored { currentTime = max(0, CMTimebaseGetTime(timebase).seconds) }
    }
    if displayLayer.status == .failed {
      stop(); state = .failed("原生画面输出失败，请返回原播放器。"); return
    }
    // The native layer schedules PTS against a host-clock timebase. DisplayLink
    // only feeds a bounded look-ahead; it does not synthesize frame timestamps.
    for _ in 0..<4 {
      if pending == nil {
        var pts = 0.0
        var frameSerial: Int32 = 0
        if let pixel = CinevaFFmpegSessionCopyFrame(handle.pointer, &pts, &frameSerial) {
          pending = (pixel, pts, frameSerial)
        }
      }
      guard let (pixel, pts, frameSerial) = pending else { break }
      guard frameSerial == serial else { pending = nil; continue }
      let clock = CMTimebaseGetTime(timebase).seconds
      if anchored && (!wantsPlayback || (state != .buffering && pts > clock + min(0.12, 2 * frameStep))) { break }
      guard displayLayer.isReadyForMoreMediaData else { break }
      var format: CMVideoFormatDescription?
      guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else {
        stop(); state = .failed("无法建立视频帧格式。"); return
      }
      var timing = CMSampleTimingInfo(duration: .invalid,
        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 60000), decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
        sampleBufferOut: &sample) == noErr, let sample else {
        stop(); state = .failed("无法建立显示采样。"); return
      }
      if !anchored || state == .buffering {
        CMTimebaseSetTime(timebase, time: timing.presentationTimeStamp)
        CMTimebaseSetRate(timebase, rate: wantsPlayback ? 1 : 0)
        anchored = true
        state = wantsPlayback ? .playing : .paused
      }
      displayLayer.enqueue(sample)
      pending = nil
      lastEnqueuedPTS = pts
      if firstFrameSeconds == nil { firstFrameSeconds = now - startedAt }
      if let seekStartedAt {
        lastSeekSeconds = now - seekStartedAt
        self.seekStartedAt = nil
      }
    }
    if anchored && wantsPlayback {
      let clock = CMTimebaseGetTime(timebase).seconds
      if clock > lastEnqueuedPTS + max(0.08, frameStep), pending == nil, snapshot.frameCount == 0 {
        CMTimebaseSetRate(timebase, rate: 0)
        state = snapshot.status == 2 ? .ended : .buffering
        if state == .ended { wantsPlayback = false }
      }
    }
    if !anchored, snapshot.status == 2, snapshot.frameCount == 0, pending == nil {
      state = .ended
      wantsPlayback = false
    }
  }
}
