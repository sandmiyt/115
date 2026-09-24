import AVFoundation
import Foundation
import Libmpv
import Metal
import Observation
import SwiftUI
import UIKit

// libmpv C API integration. Upstream versions and licensing are recorded in
// Dependencies/MPVKit-NOTICE.md. No signed URL or header is written to logs.
struct MPVTrack: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let type: String
  let selected: Bool
}

private struct MPVChapter: Sendable {
  let title: String
  let start: Double
}

private struct MPVSnapshot: Sendable {
  var time: Double = 0
  var duration: Double = 0
  var loaded = false
  var paused = false
  var waiting = true
  var seeking = false
  var ended = false
  var bytesPerSecond: Int64 = 0
  var ranges: [PlaybackBufferRange] = []
  var tracks: [MPVTrack] = []
  var chapters: [MPVChapter] = []
  var width: Double = 0
  var height: Double = 0
  var codec = "读取中"
  var decoder = "未就绪"
  var error: String?
}

/// All libmpv calls, including shutdown, run off the UI thread on one queue.
private final class MPVSession: @unchecked Sendable {
  // Serialize old-session termination before another session uses the surface.
  private static let serialQueue = DispatchQueue(label: "cineva.mpv", qos: .userInitiated)
  private var queue: DispatchQueue { Self.serialQueue }
  private var handle: OpaquePointer?
  private var initialized = false
  private var timer: DispatchSourceTimer?
  private var snapshot = MPVSnapshot()
  private var pendingSeek: (time: Double, final: Bool, resume: Bool)?
  private var seekInFlight = false
  private var seekStartedAt: TimeInterval = 0
  private var lastPublishedAt: TimeInterval = 0
  private var lastTracksAt: TimeInterval = 0
  // Keep the rendering layer alive until the GPU and demuxer have stopped.
  private let renderingLayer: CAMetalLayer
  private let publish: @Sendable (MPVSnapshot) -> Void

  init(layer: CAMetalLayer, source: VideoSource, resumeAt: Double, rate: Float,
    fastStart: Bool, publish: @escaping @Sendable (MPVSnapshot) -> Void) {
    renderingLayer = layer
    self.publish = publish
    let windowID = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
    let caPath = Bundle.main.path(forResource: "mpv-cacert", ofType: "pem")
    let memoryMiB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
    let forwardMiB = min(192, max(64, memoryMiB / 40))
    queue.async { [self] in
      guard let mpv = mpv_create() else { fail("mpv 初始化失败"); return }
      handle = mpv
      var wid = windowID
      guard mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid) >= 0 else {
        fail("mpv 无法创建画面输出"); return
      }
      let options: [(String, String)] = [
        ("config", "no"), ("terminal", "no"), ("msg-level", "all=no"),
        ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
        ("hwdec", "videotoolbox"), ("profile", "fast"),
        ("idle", "yes"), ("keep-open", "yes"), ("pause", "no"),
        ("cache", "yes"), ("cache-secs", "120"),
        ("demuxer-max-bytes", "\(forwardMiB)MiB"), ("demuxer-max-back-bytes", "32MiB"),
        ("cache-on-disk", "no"), ("cache-pause", "yes"),
        ("cache-pause-initial", fastStart ? "no" : "yes"), ("cache-pause-wait", "3"),
        ("network-timeout", "15"), ("tls-verify", "yes"),
        ("osd-level", "0"), ("input-default-bindings", "no"),
        ("sub-auto", "no"), ("audio-file-auto", "no"),
        ("speed", String(rate)), ("start", String(max(resumeAt, 0)))
      ]
      for (name, value) in options {
        guard mpv_set_option_string(mpv, name, value) >= 0 else {
          fail("mpv 不支持配置项：\(name)"); return
        }
      }
      guard let caPath, mpv_set_option_string(mpv, "tls-ca-file", caPath) >= 0 else {
        fail("mpv 缺少 HTTPS 证书资源"); return
      }
      let headers = source.headers.filter { !$0.key.contains("\r") && !$0.key.contains("\n")
        && !$0.value.contains("\r") && !$0.value.contains("\n") }
      if let agent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
        _ = mpv_set_option_string(mpv, "user-agent", agent)
      }
      // A typed string array preserves commas and avoids option-string parsing.
      let strings = headers.filter { $0.key.lowercased() != "user-agent" }
        .sorted { $0.key < $1.key }.map { strdup("\($0.key): \($0.value)") }
      defer { strings.forEach { free($0) } }
      var nodes = strings.map { pointer -> mpv_node in
        var node = mpv_node(); node.format = MPV_FORMAT_STRING; node.u.string = pointer; return node
      }
      let headerResult = nodes.withUnsafeMutableBufferPointer { buffer -> Int32 in
        var list = mpv_node_list(num: Int32(buffer.count), values: buffer.baseAddress, keys: nil)
        return withUnsafeMutablePointer(to: &list) { pointer in
          var node = mpv_node(); node.format = MPV_FORMAT_NODE_ARRAY; node.u.list = pointer
          return mpv_set_option(mpv, "http-header-fields", MPV_FORMAT_NODE, &node)
        }
      }
      guard headerResult >= 0 else { fail("mpv 无法配置请求头"); return }
      let status = mpv_initialize(mpv)
      guard status >= 0 else { fail("mpv 初始化失败（\(status)）"); return }
      initialized = true
      guard command(["loadfile", source.url.absoluteString, "replace"]) >= 0 else {
        fail("mpv 无法打开视频"); return
      }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
      timer.setEventHandler { [weak self] in self?.poll() }
      self.timer = timer
      timer.resume()
    }
  }

  func set(_ name: String, _ value: String) {
    queue.async { [self] in
      guard let handle, initialized else { return }
      if name == "pause", let pending = pendingSeek {
        pendingSeek = (pending.time, pending.final, value == "no")
      }
      _ = mpv_set_property_string(handle, name, value)
    }
  }

  func seek(_ time: Double, final: Bool, resume: Bool) {
    queue.async { [self] in pendingSeek = (max(time, 0), final, resume) }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel(); timer = nil
      guard let handle else { return }
      self.handle = nil
      if initialized { mpv_terminate_destroy(handle) } else { mpv_destroy(handle) }
      initialized = false
      // The captured self retains renderingLayer until termination finishes.
    }
  }

  private func fail(_ message: String) {
    snapshot.error = message; snapshot.waiting = false
    publish(snapshot)
    stop()
  }

  @discardableResult
  private func command(_ args: [String]) -> Int32 {
    guard let handle else { return -1 }
    let strings = args.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } }
    pointers.append(nil)
    return mpv_command_async(handle, 0, &pointers)
  }

  private func number(_ name: String) -> Double {
    var value: Double = 0
    guard let handle, mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0,
      value.isFinite else { return 0 }
    return value
  }

  private func flag(_ name: String) -> Bool {
    var value: Int32 = 0
    guard let handle, mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return false }
    return value != 0
  }

  private func string(_ name: String) -> String? {
    guard let handle, let pointer = mpv_get_property_string(handle, name) else { return nil }
    defer { mpv_free(pointer) }
    return String(cString: pointer)
  }

  private func tracks() -> [MPVTrack] {
    let count = min(max(Int(number("track-list/count")), 0), 128)
    return (0..<count).compactMap { index in
      let base = "track-list/\(index)/"
      guard let type = string(base + "type"), type == "audio" || type == "sub",
        let id = string(base + "id") else { return nil }
      let title = [string(base + "title"), string(base + "lang"), string(base + "codec")]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
      return MPVTrack(id: id, title: title.isEmpty ? "\(type == "audio" ? "音轨" : "字幕") \(index + 1)" : title,
        type: type, selected: flag(base + "selected"))
    }
  }

  private func cacheRanges() -> [PlaybackBufferRange] {
    guard let handle else { return [] }
    var node = mpv_node()
    guard mpv_get_property(handle, "demuxer-cache-state", MPV_FORMAT_NODE, &node) >= 0 else { return [] }
    defer { mpv_free_node_contents(&node) }
    func field(_ node: mpv_node, _ key: String) -> mpv_node? {
      guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee,
        list.num > 0, let keys = list.keys, let values = list.values else { return nil }
      for index in 0..<Int(list.num) {
        if let name = keys[index], String(cString: name) == key { return values[index] }
      }
      return nil
    }
    func value(_ node: mpv_node?) -> Double? {
      guard let node else { return nil }
      if node.format == MPV_FORMAT_DOUBLE { return node.u.double_ }
      if node.format == MPV_FORMAT_INT64 { return Double(node.u.int64) }
      return nil
    }
    guard let ranges = field(node, "seekable-ranges"), ranges.format == MPV_FORMAT_NODE_ARRAY,
      let list = ranges.u.list?.pointee, list.num > 0, let values = list.values else { return [] }
    return PlaybackBufferPolicy.normalized((0..<Int(list.num)).compactMap { index in
      guard let start = value(field(values[index], "start")), let end = value(field(values[index], "end")) else { return nil }
      return PlaybackBufferRange(start: start, end: end)
    })
  }

  private func poll() {
    guard let handle, initialized else { return }
    while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
      if event.event_id == MPV_EVENT_FILE_LOADED { snapshot.loaded = true }
      if event.event_id == MPV_EVENT_PLAYBACK_RESTART { seekInFlight = false }
      if event.event_id == MPV_EVENT_COMMAND_REPLY, event.error < 0 {
        fail("mpv 播放命令失败（\(event.error)）"); return
      }
      if event.event_id == MPV_EVENT_END_FILE, let data = event.data {
        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        if end.reason == MPV_END_FILE_REASON_ERROR {
          fail("mpv 无法读取视频（\(end.error)）"); return
        }
        if end.reason == MPV_END_FILE_REASON_EOF { snapshot.ended = true }
      }
    }
    let now = ProcessInfo.processInfo.systemUptime
    if let pending = pendingSeek, snapshot.loaded,
      !seekInFlight || (pending.final && now - seekStartedAt > 1) {
      pendingSeek = nil
      seekInFlight = true; seekStartedAt = now; snapshot.ended = false
      // Rapid moves use keyframes; only the committed position requests an
      // exact frame. Cached seeks are handled by mpv's native packet cache.
      _ = command(["seek", String(pending.time), pending.final ? "absolute+exact" : "absolute+keyframes"])
      _ = mpv_set_property_string(handle, "pause", pending.resume ? "no" : "yes")
    }
    snapshot.time = number("time-pos")
    snapshot.duration = number("duration")
    snapshot.paused = flag("pause")
    snapshot.waiting = !snapshot.loaded || flag("paused-for-cache")
    snapshot.seeking = seekInFlight || pendingSeek != nil || flag("seeking")
    snapshot.ended = snapshot.ended || flag("eof-reached")
    var speed: Int64 = 0
    if mpv_get_property(handle, "cache-speed", MPV_FORMAT_INT64, &speed) >= 0 {
      snapshot.bytesPerSecond = max(speed, 0)
    }
    snapshot.ranges = cacheRanges()
    if snapshot.loaded, now - lastTracksAt >= 1 {
      snapshot.tracks = tracks(); lastTracksAt = now
      snapshot.width = number("video-out-params/dw")
      snapshot.height = number("video-out-params/dh")
      snapshot.codec = string("video-codec") ?? "未知"
      snapshot.decoder = string("hwdec-current") ?? "未知"
      let count = min(max(Int(number("chapter-list/count")), 0), 1000)
      if snapshot.chapters.count != count {
        snapshot.chapters = (0..<count).map { index in
          MPVChapter(title: string("chapter-list/\(index)/title") ?? "章节 \(index + 1)",
            start: number("chapter-list/\(index)/time"))
        }
      }
    }
    if now - lastPublishedAt >= 0.25 {
      lastPublishedAt = now; publish(snapshot)
    }
  }
}

@MainActor @Observable
final class MPVPlaybackController: PlaybackEngineControlling {
  private(set) var currentTime: Double = 0
  private(set) var duration: Double = 0
  private(set) var bufferedRanges: [PlaybackBufferRange] = []
  var bufferedUntil: Double { PlaybackBufferPolicy.contiguousEnd(at: currentTime, ranges: bufferedRanges) }
  var bufferedDuration: Double { max(0, bufferedUntil - currentTime) }
  private(set) var isPlaying = false
  private(set) var isBuffering = false
  private(set) var isInteractiveScrubLoading = false
  private(set) var didReachEnd = false
  private(set) var networkMbps: Double = 0
  var transferredMegabytes: Double { 0 } // mpv does not provide a cumulative network counter.
  private(set) var volume: Float = 1
  private(set) var errorMessage: String?
  private(set) var firstPlaybackSeconds: Double?
  private(set) var playbackStallCount = 0
  private(set) var audioTracks: [MPVTrack] = []
  private(set) var subtitleTracks: [MPVTrack] = []
  private(set) var videoSize: CGSize?
  private(set) var videoCodec = "读取中"
  private(set) var decoder = "未就绪"
  private(set) var chapters: [PlayerChapter] = []
  let surface = MPVRenderSurface()
  @ObservationIgnored nonisolated(unsafe) private var session: MPVSession?
  private var generation = UUID()
  private var item: CloudItem?
  private var libraryStore: LibraryStore?
  private var dragging = false
  private var wantsPlayback = false
  private var startedAt: TimeInterval = 0
  private var lastSampleAt: TimeInterval = 0
  private var lastMediaTime: Double = 0
  private var lastWasPlaying = false
  private var lastSavedSecond = -1
  private var waitAt: TimeInterval?
  private var countedWait = false
  private var rate: Float = 1
  private var lastVideoFill: Bool?
  private var playbackIntent = 0
  private var scrubPlaybackIntent = 0
  private var backgrounded = false
  @ObservationIgnored nonisolated(unsafe) private var notifications: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.backgrounded = true
        self.session?.set("pause", "yes")
        self.session?.set("vid", "no")
      }
    })
    notifications.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.backgrounded = false
        self.session?.set("vid", "auto")
        self.session?.set("pause", self.wantsPlayback ? "no" : "yes")
      }
    })
    notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.pause() }
    })
    notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        Task { @MainActor [weak self] in self?.pause() }
      }
    })
  }

  deinit {
    session?.stop()
    for token in notifications { NotificationCenter.default.removeObserver(token) }
  }

  func configure(source: VideoSource, item: CloudItem, libraryStore: LibraryStore,
    playbackRate: Float, fastStartEnabled: Bool, resumeAt: Double? = nil) {
    stop(saveProgress: false)
    self.item = item; self.libraryStore = libraryStore
    duration = max(item.duration, libraryStore.knownDuration(for: item))
    let resume = resumeAt ?? libraryStore.resumePosition(for: item)
    let position = resume > 0 && (resumeAt != nil || (resume > 2 && (duration <= 0 || resume < duration - 15))) ? resume : 0
    currentTime = position; lastMediaTime = position
    lastVideoFill = nil
    bufferedRanges = []; errorMessage = nil; didReachEnd = false
    audioTracks = []; subtitleTracks = []
    chapters = []; videoSize = nil; videoCodec = "读取中"; decoder = "未就绪"
    firstPlaybackSeconds = nil; playbackStallCount = 0; lastSavedSecond = -1
    waitAt = nil; countedWait = false; lastWasPlaying = false
    isBuffering = true; wantsPlayback = true
    rate = min(max(playbackRate, 0.5), 2)
    startedAt = ProcessInfo.processInfo.systemUptime; lastSampleAt = startedAt
    let token = generation
    session = MPVSession(layer: surface.metalLayer, source: source, resumeAt: position,
      rate: rate, fastStart: fastStartEnabled) { [weak self] snapshot in
        Task { @MainActor [weak self] in
          guard let self, self.generation == token else { return }
          self.update(snapshot)
        }
      }
  }

  private func update(_ sample: MPVSnapshot) {
    let now = ProcessInfo.processInfo.systemUptime
    let playing = sample.loaded && !sample.paused && !sample.waiting && !sample.seeking && !sample.ended && sample.error == nil
    let delta = sample.time - lastMediaTime
    if firstPlaybackSeconds == nil, playing, lastWasPlaying, delta > 0.02,
      delta <= (now - lastSampleAt) * Double(rate) + 0.3 {
      firstPlaybackSeconds = now - startedAt
    }
    lastWasPlaying = playing; lastMediaTime = sample.time; lastSampleAt = now
    if !dragging { currentTime = sample.loaded ? sample.time : currentTime }
    if sample.duration > 0 { duration = sample.duration }
    if bufferedRanges != sample.ranges { bufferedRanges = sample.ranges }
    let audio = sample.tracks.filter { $0.type == "audio" }
    let subtitles = sample.tracks.filter { $0.type == "sub" }
    if audioTracks != audio { audioTracks = audio }
    if subtitleTracks != subtitles { subtitleTracks = subtitles }
    if sample.width > 0 && sample.height > 0 { videoSize = CGSize(width: sample.width, height: sample.height) }
    videoCodec = sample.codec; decoder = sample.decoder
    let loadedChapters = sample.chapters.enumerated().map { index, chapter in
      PlayerChapter(id: "mpv-\(index)", title: chapter.title, start: chapter.start,
        end: index + 1 < sample.chapters.count ? sample.chapters[index + 1].start : sample.duration)
    }
    if chapters != loadedChapters { chapters = loadedChapters }
    networkMbps = Double(sample.bytesPerSecond) * 8 / 1_000_000
    isPlaying = playing && !dragging && !backgrounded
    isBuffering = wantsPlayback && !dragging && !backgrounded && sample.waiting && sample.error == nil
    isInteractiveScrubLoading = !dragging && sample.seeking
    didReachEnd = sample.ended; errorMessage = sample.error
    if isBuffering, firstPlaybackSeconds != nil, !sample.seeking {
      if waitAt == nil { waitAt = now }
      if now - (waitAt ?? now) >= 1, !countedWait { playbackStallCount += 1; countedWait = true }
    } else { waitAt = nil; countedWait = false }
    if playing || didReachEnd { saveProgress(force: didReachEnd) }
  }

  func pause() { playbackIntent &+= 1; wantsPlayback = false; session?.set("pause", "yes"); isPlaying = false; isBuffering = false; saveProgress(force: true) }
  func resume() { playbackIntent &+= 1; wantsPlayback = true; didReachEnd = false; session?.set("pause", "no") }
  func togglePlayback() { wantsPlayback ? pause() : resume() }
  func seek(to seconds: Double) { session?.seek(clamp(seconds), final: true, resume: wantsPlayback); isInteractiveScrubLoading = true }
  func seekBy(_ delta: Double) { seek(to: currentTime + delta) }
  func setPlaybackRate(_ value: Float) { rate = min(max(value, 0.5), 2); session?.set("speed", String(rate)) }
  func setVolume(_ value: Float) { volume = min(max(value, 0), 1); session?.set("volume", String(volume * 100)) }
  func replay() { wantsPlayback = true; seek(to: 0) }
  func replayFromStart() { replay() }
  func beginInteractiveScrub() -> Bool {
    let resume = wantsPlayback
    scrubPlaybackIntent = playbackIntent
    dragging = true; session?.set("pause", "yes"); isPlaying = false; isBuffering = false
    return resume
  }
  func interactiveScrub(to time: Double) { currentTime = clamp(time); session?.seek(currentTime, final: false, resume: false) }
  func endInteractiveScrub(to time: Double, resumeAfter: Bool) {
    let shouldResume = scrubPlaybackIntent == playbackIntent ? resumeAfter : wantsPlayback
    dragging = false; wantsPlayback = shouldResume
    currentTime = clamp(time); isInteractiveScrubLoading = true
    session?.seek(currentTime, final: true, resume: shouldResume)
  }
  func stop(saveProgress: Bool = true) {
    if saveProgress { self.saveProgress(force: true) }
    generation = UUID(); session?.stop(); session = nil
    dragging = false; wantsPlayback = false; isPlaying = false; isBuffering = false; isInteractiveScrubLoading = false
  }
  func setVideoLayout(_ fill: Bool) {
    guard lastVideoFill != fill else { return }
    lastVideoFill = fill; session?.set("panscan", fill ? "1" : "0")
  }
  func selectAudio(_ id: String?) { session?.set("aid", id ?? "auto") }
  func selectSubtitle(_ id: String?) { session?.set("sid", id ?? "no") }
  private func clamp(_ time: Double) -> Double { min(max(time, 0), duration > 0 ? duration : max(time, 0)) }
  private func saveProgress(force: Bool) {
    guard firstPlaybackSeconds != nil, !dragging, !isInteractiveScrubLoading, let item, let libraryStore else { return }
    let second = Int(max(currentTime, 0))
    if force || abs(second - lastSavedSecond) >= 5 {
      lastSavedSecond = second; libraryStore.recordPlayback(item, position: currentTime, duration: duration)
    }
  }
  var playbackDiagnosticText: String {
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    let start = firstPlaybackSeconds.map { String(format: "%.2f s", $0) } ?? "未起播"
    return """
      Cineva \(version) · mpv · 直连
      实际起播（采样）：\(start)
      解码方式：\(decoder) · 编码：\(videoCodec)
      状态：\(isBuffering ? "等待缓存" : (isPlaying ? "播放中" : "暂停或定位"))
      连续可跳转缓存：\(String(format: "%.2f s", bufferedDuration))
      当前读取速度（1 秒窗口）：\(String(format: "%.2f Mbps", networkMbps))
      播放中缓冲：\(playbackStallCount) 次
      """
  }
}

// MPVKit's MoltenVK context renders into this layer. Ignore its transient 1x1
// teardown resize, as documented by MPVKit (see bundled third-party notices).
final class CinevaMPVMetalLayer: CAMetalLayer {
  override var drawableSize: CGSize {
    get { super.drawableSize }
    set { if newValue.width > 1 && newValue.height > 1 { super.drawableSize = newValue } }
  }
}

@MainActor
final class MPVRenderSurface: UIView {
  override class var layerClass: AnyClass { CinevaMPVMetalLayer.self }
  var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
  init() {
    super.init(frame: UIScreen.main.bounds)
    backgroundColor = .black
    metalLayer.device = MTLCreateSystemDefaultDevice()
    metalLayer.contentsScale = UIScreen.main.scale
    metalLayer.framebufferOnly = true
    layoutSubviews()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = window?.screen.scale ?? UIScreen.main.scale
    metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 2), height: max(bounds.height * scale, 2))
  }
}

struct MPVPlayerView: UIViewRepresentable {
  let controller: MPVPlaybackController
  let fill: Bool
  func makeUIView(context: Context) -> MPVRenderSurface { controller.surface }
  func updateUIView(_ uiView: MPVRenderSurface, context: Context) { controller.setVideoLayout(fill) }
}
