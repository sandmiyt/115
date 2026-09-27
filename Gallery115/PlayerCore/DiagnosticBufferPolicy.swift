import Foundation

/// Only used by the experimental FFmpeg validation session. All units are seconds.
struct DiagnosticBufferPolicy {
  let startupBufferTarget = 0.75
  private(set) var rebufferTarget = 2.0
  private(set) var stallCount = 0
  private(set) var runway = 0.0
  private(set) var resumeTarget = 0.75
  private(set) var capacityLimited = false
  private var rebuffering = false
  private var consecutiveStalls = 0
  private var lastStallAt: Double?
  private var waitingSince = 0.0

  mutating func prepare(at now: Double) {
    rebuffering = false
    waitingSince = now
    runway = 0
    resumeTarget = startupBufferTarget
    capacityLimited = false
  }

  mutating func starved(at now: Double) {
    consecutiveStalls = lastStallAt.map { now - $0 <= 30 ? consecutiveStalls + 1 : 1 } ?? 1
    lastStallAt = now
    stallCount += 1
    rebufferTarget = min(5, Double(consecutiveStalls + 1))
    rebuffering = true
    waitingSince = now
    capacityLimited = false
  }

  mutating func canResume(compressed: Double, decoded: Double, pending: Double,
                          submitted: Double, hasFrame: Bool, ioLatency: Double,
                          eof: Bool, backpressured: Bool, now: Double) -> Bool {
    func valid(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    runway = valid(compressed) + valid(decoded) + valid(pending) + valid(submitted)
    if rebuffering { rebufferTarget = max(rebufferTarget, min(5, 2.5 * valid(ioLatency))) }
    resumeTarget = rebuffering ? rebufferTarget : startupBufferTarget
    capacityLimited = false
    guard hasFrame, runway > 0 else { return false }
    if eof { return true } // Drain a short clip/tail; waiting for two seconds would deadlock.
    if runway >= resumeTarget { return true }
    // A high-bitrate stream can fill the existing byte/packet cap before reaching
    // the time target. Do not enlarge RAM or wait forever. Disclose the exception.
    if backpressured, valid(decoded) > 0, now - waitingSince >= resumeTarget {
      capacityLimited = true
      return true
    }
    return false
  }
}

enum FFmpegReadMode: String, CaseIterable, Identifiable {
  case videoOnlyStandard, videoOnlySequential, standard, directAudio, cachedAudio, decodeAudio
  var id: Self { self }
  var videoOnly: Bool { self == .videoOnlySequential || self == .videoOnlyStandard }
  var outputsAudio: Bool { self == .standard || self == .directAudio || self == .cachedAudio }
  var title: String {
    switch self {
    case .videoOnlyStandard: return "Video-only + 标准读取"
    case .videoOnlySequential: return "Video-only + 顺序读取（稳定对照）"
    case .standard: return "音视频输出 + FFmpeg 原生 HTTP"
    case .directAudio: return "音视频输出 + Custom AVIO 直读（绕过缓存）"
    case .cachedAudio: return "音视频输出 + Custom AVIO 缓存"
    case .decodeAudio: return "音频仅解码 + 旧 HTTP（不输出声音）"
    }
  }
}

/// Value copy retained by the validation view when switching A/B. Never carries
/// the signed URL or request headers. The view supplies the SAME VideoSource.
struct FFmpegDiagnosticTrial: Identifiable {
  let id = UUID()
  let mode: FFmpegReadMode
  let position: Double
  let hardware: Bool
  var firstFrame: Double?
  var firstPlayback: Double?
  var elapsed = 0.0
  var stalls = 0
  var bytes: Int64 = 0
  var backwards = 0
  var forwards = 0
  var averageRead = 0.0
  var maximumRead = 0.0
  var compressed = 0.0
  var complete = false
  var interruption: String?
  var httpRequests: Int?
  var networkBytes: Int64?
  var cacheHitBytes: Int64?

  var text: String {
    func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? "尚未发生" }
    return mode.title + String(format: " · 起点 %.3f s · %@\n", position, hardware ? "优先硬解" : "软件对照")
      + "首帧入队 \(seconds(firstFrame)) · 实际起播 \(seconds(firstPlayback))\n"
      + String(format: "起播后观察 %.2f / 10 s · buffering %d 次 · %@\n", elapsed, stalls,
        complete ? "10 秒窗口已固定" : "窗口未完成")
      + String(format: "AVIO 累计 %.2f MiB · packet jump 回退 %d / 前跳 >1 MiB %d\n", Double(bytes) / 1048576, backwards, forwards)
      + String(format: "取包平均 %.4f s / 最大 %.4f s · 压缩视频队列 %.3f s", averageRead, maximumRead, compressed)
      + (interruption.map { "\n对照标记：" + $0 } ?? "")
      + (httpRequests.map { "\n真实 HTTP requests \($0) · 网络 bytes \(networkBytes ?? 0) · 缓存命中 bytes \(cacheHitBytes ?? 0)（以实际命中区分冷/暖）" } ?? "")
  }
}

/// The input alone varies; audio, decoder and renderer stay identical.
enum FFmpegInputBackend: String, Sendable {
  case ffmpegHTTP, customAVIODirect, customAVIOCached
  var trialMode: FFmpegReadMode {
    switch self { case .ffmpegHTTP: return .standard; case .customAVIODirect: return .directAudio; case .customAVIOCached: return .cachedAudio }
  }
}

struct FFmpegFailureSnapshot: Sendable {
  let session: UUID
  let generation: Int32
  let backend: FFmpegInputBackend
  let build: String
  let stage: String
  let nativeError: Int32
  let transport: String
  let operations: String
  var text: String {
    "Cineva \(build) · FFmpeg failure (frozen before teardown)\n"
    + "session=\(session.uuidString) · generation=\(generation) · backend=\(backend.rawValue)\n"
    + "stage=\(stage) · FFmpeg=\(nativeError)\n" + transport + "\n" + operations
  }
  static func stageName(_ value: Int32) -> String {
    switch value {
    case 1:return "打开媒体"
    case 2:return "探测流信息"
    case 3:return "选择视频轨"
    case 4:return "打开视频解码器"
    case 5:return "打开音频解码器"
    case 6:return "定位媒体"
    case 7:return "读取媒体包"
    case 8:return "视频解码"
    case 9:return "音频解码"
    case 10:return "视频表面输出"
    case 11:return "启动工作线程"
    default:return "引擎控制 / 尚无原生失败阶段"
    }
  }
}
