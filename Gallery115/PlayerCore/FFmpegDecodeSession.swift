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

/// Phase 5 validation transport. Intentionally not a full PlayerEngine: audio,
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
  let renderer = NativeVideoRenderer()
  var displayLayer: AVSampleBufferDisplayLayer { renderer.layer }
  private(set) var renderingDescription = "等待首帧"
  private(set) var pipelineDescription = "正在打开媒体"
  private(set) var submittedFrames = 0
  private(set) var droppedFrames = 0
  private(set) var renderRecoveries = 0
  private(set) var displayReady = false
  private(set) var timingDescription = "等待时间戳"

  var diagnosticText: String {
    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
    return "Cineva \(version) (\(build)) · FFmpeg 无声验证\n"
      + "\(mediaDescription)\n\(decoderDescription)\n\(outputDescription)\n\(colorDescription)\n"
      + "状态：\(state.title) · \(pipelineDescription)\n\(timingDescription)\n"
      + "解码：\(videoFrames) 帧；显示入队：\(submittedFrames)；丢帧：\(droppedFrames)；显示恢复：\(renderRecoveries)\n"
      + "队列：\(packetBytes / 1024) KB / \(frameCount) 帧；首帧可显示：\(displayReady)\n"
      + (fallbackDescription ?? "")
  }

  @ObservationIgnored private var handle: FFmpegSessionHandle?
  @ObservationIgnored private var displayLink: CADisplayLink?
  @ObservationIgnored private var pending: (CVPixelBuffer, Double, Int32)?
  @ObservationIgnored private var serial: Int32 = 1
  @ObservationIgnored private var startedAt = 0.0
  @ObservationIgnored private var seekStartedAt: Double?
  @ObservationIgnored private var lastPublishedAt = 0.0
  @ObservationIgnored private var frameStep = 1.0 / 30.0

  func start(source: VideoSource, at seconds: Double, preferHardware: Bool = true) {
    guard handle == nil else { return }
    let start = seconds.isFinite ? max(0, seconds) : 0
    renderer.reset(to: start, newSession: true)
    pending = nil
    frameStep = 1.0 / 30.0
    lastPublishedAt = 0
    duration = 0
    videoFrames = 0
    audioFrames = 0
    packetBytes = 0
    frameCount = 0
    submittedFrames = 0
    droppedFrames = 0
    renderRecoveries = 0
    displayReady = false
    serial = 1
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
      renderer.available else { state = .failed("验证入口仅支持 HTTP/HTTPS 视频地址。"); return }
    // Prevent header injection. Headers come from the existing provider, not UI.
    let validHeaders = source.headers.allSatisfy { key, value in
      !key.isEmpty && !key.contains(":") && !key.contains(where: { $0.isNewline }) &&
        !value.contains(where: { $0.isNewline })
    }
    guard validHeaders else { state = .failed("播放请求头格式无效。"); return }
    let headers = source.headers.sorted { $0.key < $1.key }
      .map { "\($0.key): \($0.value)\r\n" }.joined()
    let pointer = source.url.absoluteString.withCString { url in
      headers.withCString { CinevaFFmpegSessionCreate(url, $0, start, preferHardware ? 1 : 0) }
    }
    guard let pointer else { state = .failed("无法创建 FFmpeg 解码会话。"); return }
    handle = FFmpegSessionHandle(pointer)
    state = .preparing
    currentTime = start
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
    pending = nil
    renderer.reset(to: currentTime)
    handle = nil
    state = .stopped
  }

  func toggle() {
    if state == .ended { wantsPlayback = true; seek(to: 0); return }
    wantsPlayback.toggle()
    renderer.setPlaying(wantsPlayback)
    if renderer.anchored { state = wantsPlayback ? (renderer.waitingForData ? .buffering : .playing) : .paused }
  }

  func seek(to seconds: Double) {
    guard let handle, duration > 0, seconds.isFinite else { return }
    let target = min(max(0, seconds), max(0, duration - 0.1))
    serial = CinevaFFmpegSessionSeek(handle.pointer, target)
    pending = nil
    currentTime = target
    seekStartedAt = CACurrentMediaTime()
    renderer.reset(to: target)
    state = .seeking
  }

  fileprivate func pump() {
    guard let handle else { return }
    var snapshot = CinevaFFmpegSnapshot()
    CinevaFFmpegSessionSnapshot(handle.pointer, &snapshot)
    if snapshot.status < 0 {
      let code = snapshot.errorCode
      let av1SoftwareUnavailable = snapshot.fallbackReason > 0 &&
        String(cString: CinevaFFmpegCodecName(snapshot.videoCodec)) == "av1"
      stop()
      state = .failed(av1SoftwareUnavailable
        ? "本构建尚未集成 AV1 软件解码器。请尝试开启优先硬解，或返回原播放器使用 VLC。"
        : code == -70001
        ? "检测到 Dolby Vision，本阶段尚未接入其动态元数据处理。请返回原播放器使用系统内核。"
        : "FFmpeg 验证未能继续（\(code)）。可能是地址过期、网络超时或格式暂不支持。请返回原播放器。")
      return
    }
    // Decoder failure can trigger an internal keyframe restart in software.
    // Treat it exactly like a new seek; no old hardware frame may reappear.
    if snapshot.serial != serial {
      serial = snapshot.serial
      pending = nil
      currentTime = snapshot.recoveryTarget
      renderer.reset(to: currentTime)
      state = .seeking
    }
    if renderer.anchored { CinevaFFmpegSessionSetPosition(handle.pointer, renderer.time) }
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
        let transfer = snapshot.colorTransfer == 16 ? "HDR10 / PQ" : (snapshot.colorTransfer == 18 ? "HLG" : "未标记 PQ / HLG")
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
        if snapshot.fps.isFinite, snapshot.fps > 0 { frameStep = 1 / min(240, max(1, snapshot.fps)) }
      }
      if renderer.anchored { currentTime = max(0, renderer.time) }
      submittedFrames = renderer.submittedFrames
      droppedFrames = renderer.droppedFrames
      renderRecoveries = renderer.recoveryCount
      renderingDescription = renderer.waitReason
      displayReady = displayLayer.isReadyForDisplay
      timingDescription = String(format: "时钟 %.3f s · 最近入队 %.3f s", renderer.time, renderer.lastPTS)
        + (pending.map { String(format: " · 下一帧 %.3f s", $0.1) } ?? " · 下一帧未就绪")
      if pending != nil || snapshot.frameCount > 0 {
        pipelineDescription = "已有解码帧 · " + renderer.waitReason
      } else if snapshot.packetCount > 0 {
        pipelineDescription = "已有压缩数据 · 等待视频解码输出"
      } else {
        pipelineDescription = snapshot.status == 2 ? "解码已结束" : "等待解封装 / 网络数据"
      }
    }
    // Bounded feeding; native output schedules against its host timebase.
    // Polling never performs network reads, software decoding or pixel copies.
    for _ in 0..<8 {
      if pending == nil {
        var pts = 0.0
        var frameSerial: Int32 = 0
        if let pixel = CinevaFFmpegSessionCopyFrame(handle.pointer, &pts, &frameSerial) {
          pending = (pixel, pts, frameSerial)
        }
      }
      guard let (pixel, pts, frameSerial) = pending else { break }
      guard frameSerial == serial else { pending = nil; continue }
      let result = renderer.submit(pixel, pts: pts, duration: frameStep, playing: wantsPlayback, now: now)
      switch result {
      case .accepted:
        pending = nil
        state = wantsPlayback ? .playing : .paused
        if firstFrameSeconds == nil { firstFrameSeconds = now - startedAt }
        if let seekStartedAt {
          lastSeekSeconds = now - seekStartedAt
          self.seekStartedAt = nil
        }
      case .dropped:
        pending = nil
      case .failed(let message):
        stop(); state = .failed(message); return
      case .waiting:
        break
      }
      if case .waiting = result { break }
    }
    // The worker changes queues concurrently. Never decide starvation/EOF from
    // the snapshot taken before consuming frames at the beginning of this tick.
    CinevaFFmpegSessionSnapshot(handle.pointer, &snapshot)
    guard snapshot.serial == serial, snapshot.status >= 0 else { return }
    if renderer.anchored && wantsPlayback && !renderer.waitingForData {
      if renderer.time > renderer.lastEnd + 0.15, pending == nil, snapshot.frameCount == 0 {
        renderer.suspendForData()
        state = snapshot.status == 2 ? .ended : .buffering
        if state == .ended { wantsPlayback = false }
      }
    }
    if (!renderer.anchored || renderer.waitingForData), snapshot.status == 2,
      snapshot.frameCount == 0, pending == nil {
      state = .ended
      wantsPlayback = false
      renderer.setPlaying(false)
    }
  }
}
