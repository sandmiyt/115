import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import UIKit


struct PlayerChapter: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let start: Double
  let end: Double
}

struct SubtitleCue: Identifiable, Hashable, Sendable {
  let id: Int
  let start: Double
  let end: Double
  let text: String
}

@MainActor
protocol PlaybackEngineControlling: AnyObject {
  var currentTime: Double { get }
  var duration: Double { get }
  var bufferedUntil: Double { get }
  var bufferedDuration: Double { get }
  var isPlaying: Bool { get }
  var isBuffering: Bool { get }
  var didReachEnd: Bool { get }
  var networkMbps: Double { get }
  var transferredMegabytes: Double { get }
  var volume: Float { get }
  func pause()
  func resume()
  func togglePlayback()
  func seek(to seconds: Double)
  func setPlaybackRate(_ rate: Float)
  func setVolume(_ value: Float)
  func replayFromStart()
}

typealias CinevaPlaybackEngine = PlaybackEngineControlling

@MainActor
extension PlaybackEngineControlling {
  func enginePause() { pause() }
  func engineResume() { resume() }
  func engineTogglePlayback() { togglePlayback() }
  func engineSeek(to seconds: Double) { seek(to: seconds) }
  func engineSetPlaybackRate(_ rate: Float) { setPlaybackRate(rate) }
  func engineSetVolume(_ value: Float) { setVolume(value) }
}

enum ExternalSubtitleParser {
  nonisolated static func parse(data: Data, fileExtension: String) -> [SubtitleCue] {
    guard let text = decodeText(data) else { return [] }
    return ["ass", "ssa"].contains(fileExtension.lowercased()) ? parseASS(text) : parseSRTLike(text)
  }

  nonisolated private static func decodeText(_ data: Data) -> String? {
    if let value = String(data: data, encoding: .utf8) { return value }
    if let value = String(data: data, encoding: .utf16) { return value }
    if let value = String(data: data, encoding: .unicode) { return value }
    if let value = String(data: data, encoding: .windowsCP1252) { return value }
    return nil
  }

  nonisolated private static func parseSRTLike(_ text: String) -> [SubtitleCue] {
    let cleaned = text.replacingOccurrences(of: "WEBVTT", with: "")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var cues: [SubtitleCue] = []
    var identifier = 0
    for block in cleaned.components(separatedBy: "\n\n") {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
      let pair = lines[timingIndex].components(separatedBy: "-->")
      guard pair.count == 2, let start = parseTimestamp(pair[0]), let end = parseTimestamp(pair[1]), end > start else { continue }
      let body = lines.dropFirst(timingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      cues.append(SubtitleCue(id: identifier, start: start, end: end, text: stripMarkup(body)))
      identifier += 1
    }
    return cues
  }

  nonisolated private static func parseASS(_ text: String) -> [SubtitleCue] {
    var format: [String] = []
    var inEvents = false
    var cues: [SubtitleCue] = []
    var identifier = 0
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if lowered == "[events]" { inEvents = true; continue }
      guard inEvents else { continue }
      if lowered.hasPrefix("format:") {
        format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        continue
      }
      guard lowered.hasPrefix("dialogue:") else { continue }
      let body = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
      let splitCount = max(format.count - 1, 9)
      let fields = body.split(separator: ",", maxSplits: splitCount, omittingEmptySubsequences: false).map(String.init)
      let startIndex = format.firstIndex(of: "start") ?? 1
      let endIndex = format.firstIndex(of: "end") ?? 2
      let textIndex = format.firstIndex(of: "text") ?? min(9, max(fields.count - 1, 0))
      guard fields.indices.contains(startIndex), fields.indices.contains(endIndex), fields.indices.contains(textIndex), let start = parseTimestamp(fields[startIndex]), let end = parseTimestamp(fields[endIndex]), end > start else { continue }
      let subtitle = stripMarkup(fields[textIndex].replacingOccurrences(of: "\\N", with: "\n"))
      guard !subtitle.isEmpty else { continue }
      cues.append(SubtitleCue(id: identifier, start: start, end: end, text: subtitle))
      identifier += 1
    }
    return cues
  }

  nonisolated private static func parseTimestamp(_ raw: String) -> Double? {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? raw
    let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
    guard parts.count >= 2 else { return nil }
    let seconds = Double(String(parts.last!)) ?? 0
    let minutes = Double(String(parts[parts.count - 2])) ?? 0
    let hours = parts.count >= 3 ? (Double(String(parts[parts.count - 3])) ?? 0) : 0
    return hours * 3600 + minutes * 60 + seconds
  }

  nonisolated private static func stripMarkup(_ value: String) -> String {
    var output = value.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
    output = output.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    output = output.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct PlayerMediaOption: Identifiable {
  let id: String
  let title: String
  fileprivate let option: AVMediaSelectionOption
}

@MainActor
@Observable
final class PlayerModel: PlaybackEngineControlling {
  private(set) var sources: [VideoSource] = []
  private(set) var selectedSource: VideoSource?
  private(set) var isPreparing = false
  private(set) var currentTime: Double = 0
  private(set) var duration: Double = 0
  private(set) var bufferedUntil: Double = 0
  private(set) var bufferedRanges: [PlaybackBufferRange] = []
  private(set) var isPlaying = false
  private(set) var didReachEnd = false
  private(set) var isBuffering = false
  private(set) var isInteractiveScrubLoading = false
  private(set) var videoDisplaySize: CGSize?
  private(set) var audioOptions: [PlayerMediaOption] = []
  private(set) var subtitleOptions: [PlayerMediaOption] = []
  private(set) var selectedAudioOptionID: String?
  private(set) var selectedSubtitleOptionID: String?
  private(set) var networkMbps: Double = 0
  private(set) var transferredMegabytes: Double = 0
  private(set) var requiresVLC = false
  private(set) var engineSwitchResumePosition: Double?
  private(set) var engineSwitchReason: String?
  private(set) var waitingStatus = "准备播放"
  private(set) var videoCodec = "读取中"
  private(set) var hdrFormat = "SDR"
  private(set) var nominalFrameRate: Float = 0
  private(set) var chapters: [PlayerChapter] = []

  var errorMessage: String?
  var didFallbackFromOriginal = false
  var allowsAutomaticEngineSwitch = true

  let player = AVPlayer()
  let timelinePreview = TimelinePreviewController()
  var volume: Float { player.volume }

  private let item: CloudItem
  private let api: APIClient
  private let libraryStore: LibraryStore
  private let defaultQuality: AppState.DefaultQuality
  private let originalPlaybackEngine: AppState.OriginalPlaybackEngine
  private let fastStartEnabled: Bool
  private let networkAutoRecoveryEnabled: Bool
  private var activeAsset: AVURLAsset?
  nonisolated(unsafe) private var rangeCache: PlaybackRangeCache?
  private var bypassRangeCache = false
  private var switchingCacheTransport = false
  private(set) var diskBufferedMegabytes: Double = 0
  private(set) var playbackTransport = "直连"
  private var mediaInfoGeneration = UUID()
  private var audioGroup: AVMediaSelectionGroup?
  private var subtitleGroup: AVMediaSelectionGroup?
  nonisolated(unsafe) private var playbackTimer: Timer?
  @ObservationIgnored private var deferredSourcesTask: Task<Void, Never>?
  nonisolated(unsafe) private var failureObserver: NSObjectProtocol?
  nonisolated(unsafe) private var endObserver: NSObjectProtocol?
  nonisolated(unsafe) private var stallObserver: NSObjectProtocol?
  nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
  nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
  nonisolated(unsafe) private var externalPlaybackObserver: NSKeyValueObservation?
  private var lastSavedSecond = -1
  private var lastRemoteHistorySecond = -60
  private var isFallingBack = false
  private var lastTransferredBytes: Int64 = 0
  private var lastBandwidthSampleAt = Date()
  private var lastStallRecoveryAt = Date.distantPast
  private var lastPlaybackProgressAt = Date()
  private var lastPlaybackProgressTime: Double = 0
  private var wantsPlayback = false
  private var hasPlayedCurrentItem = false
  private var pendingInitialPosition: Double = 0
  private var bufferingStartedAt: Date?
  private var countedCurrentStall = false
  private var sustainedStalls: [Date] = []
  private var bufferStallCount = 0
  private var preferredBufferSeconds: Double = 0
  private var interactiveScrubActive = false
  private var stallProbeTask: Task<Void, Never>?

  // The main player seeks only on release. A generation guard also handles a
  // new drag beginning before the preceding release seek has completed.
  private var scrubSeekInProgress = false
  private var scrubChaseTime: CMTime = .invalid
  private var scrubFinalTarget: CMTime?
  private var scrubResumeAfterFinish = false
  @ObservationIgnored private var scrubDispatchTask: Task<Void, Never>?
  private var scrubInFlightTarget: CMTime = .invalid
  private var scrubGeneration = 0

  init(
    item: CloudItem, api: APIClient, libraryStore: LibraryStore,
    defaultQuality: AppState.DefaultQuality,
    originalPlaybackEngine: AppState.OriginalPlaybackEngine = .automatic,
    fastStartEnabled: Bool = true,
    networkAutoRecoveryEnabled: Bool = true
  ) {
    self.item = item
    self.api = api
    self.libraryStore = libraryStore
    self.defaultQuality = defaultQuality
    self.originalPlaybackEngine = originalPlaybackEngine
    self.fastStartEnabled = fastStartEnabled
    self.networkAutoRecoveryEnabled = networkAutoRecoveryEnabled
    self.duration = max(item.duration, libraryStore.knownDuration(for: item))
    player.automaticallyWaitsToMinimizeStalling = true
    player.allowsExternalPlayback = true
    configureAudioSession()
    installAudioSessionObservers()
    externalPlaybackObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
      guard change.newValue == true else { return }
      Task { @MainActor [weak self] in self?.prepareForExternalPlayback() }
    }
  }

  deinit {
    rangeCache?.stop()
    playbackTimer?.invalidate()
    deferredSourcesTask?.cancel()
    if let failureObserver {
      NotificationCenter.default.removeObserver(failureObserver)
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    if let stallObserver {
      NotificationCenter.default.removeObserver(stallObserver)
    }
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
    }
    if let routeChangeObserver {
      NotificationCenter.default.removeObserver(routeChangeObserver)
    }
  }

  func prepareAndPlay() async {
    guard !Task.isCancelled, !isPreparing else { return }
    activateAudioSession()
    isPreparing = true
    didReachEnd = false
    defer { isPreparing = false }

    do {
      let initial = try await api.initialVideoSources(for: item, preferOriginal: defaultQuality == .original)
      try Task.checkCancellation()
      sources = initial.sources
      guard !sources.isEmpty else {
        errorMessage = "媒体源没有返回可播放地址。"
        return
      }

      let preferred: VideoSource?
      switch defaultQuality {
      case .highestTranscode:
        preferred = bestTranscode ?? original ?? sources.first
      case .fullHD:
        preferred = VideoSource.preferred1080p(in: sources)
      case .original:
        preferred = original ?? bestTranscode ?? sources.first
      }
      if let preferred {
        await play(preferred, allowFallback: true)
      }
      installTimeObserverIfNeeded()
      if initial.hasDeferredTranscodes { loadRemainingSources() }
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func loadRemainingSources() {
    deferredSourcesTask?.cancel()
    let api = self.api
    let item = self.item
    deferredSourcesTask = Task { @MainActor [weak self] in
      do {
        // Other quality URLs are only needed for optional previews/fallbacks.
        // A fixed two-second delay still competes with a slow original start.
        while let self, !self.requiresVLC,
          !self.hasPlayedCurrentItem || self.isBuffering || self.bufferedDuration < 10 {
          try await Task.sleep(for: .seconds(1))
        }
        try Task.checkCancellation()
        let remaining = try await api.remainingVideoSources(for: item)
        guard let self, !Task.isCancelled else { return }
        let existingIDs = Set(self.sources.map(\.id))
        self.sources.append(contentsOf: remaining.filter { !existingIDs.contains($0.id) })
        self.configureTimelinePreviewSource()
      } catch { /* Original playback continues even when other qualities are unavailable. */ }
    }
  }

  func select(_ source: VideoSource) async {
    didFallbackFromOriginal = false
    await play(source, allowFallback: true)
  }

  func pause() {
    wantsPlayback = false
    bufferingStartedAt = nil
    countedCurrentStall = false
    stallProbeTask?.cancel()
    stallProbeTask = nil
    cancelInteractiveScrub()
    player.pause()
    isPlaying = false
    isBuffering = false
    saveProgress(force: true)
  }

  func resume() {
    wantsPlayback = true
    lastPlaybackProgressAt = Date()
    didReachEnd = false
    activateAudioSession()
    player.play()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }

  func replayFromStart() {
    wantsPlayback = true
    lastPlaybackProgressAt = Date()
    cancelInteractiveScrub()
    stallProbeTask?.cancel()
    stallProbeTask = nil
    didReachEnd = false
    currentTime = 0
    bufferedUntil = max(bufferedUntil, 0)
    player.seek(to: .zero)
    player.play()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }

  func replay() async { replayFromStart() }

  func togglePlayback() {
    if player.timeControlStatus == .playing {
      pause()
    } else {
      resume()
    }
  }

  func seek(to seconds: Double) {
    cancelInteractiveScrub()
    stallProbeTask?.cancel()
    stallProbeTask = nil
    lastPlaybackProgressAt = Date()
    let target = clampedSeekTarget(seconds)
    currentTime = target
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
  }

  /// Keep the primary decoder and its forward buffer untouched while dragging.
  /// Preview frames have their own bounded cache; commit only on release.
  @discardableResult
  func beginInteractiveScrub() -> Bool {
    let shouldResume = scrubResumeAfterFinish || isPlaying || player.timeControlStatus != .paused || player.rate > 0
    cancelInteractiveScrub()
    interactiveScrubActive = true
    bufferingStartedAt = nil
    countedCurrentStall = false
    stallProbeTask?.cancel()
    stallProbeTask = nil
    player.pause()
    isPlaying = false
    isBuffering = false
    scrubChaseTime = player.currentTime()
    timelinePreview.begin(at: currentTime)
    return shouldResume
  }

  func interactiveScrub(to seconds: Double) {
    guard interactiveScrubActive, scrubFinalTarget == nil else { return }
    let target = CMTime(seconds: clampedSeekTarget(seconds), preferredTimescale: 600)
    currentTime = target.seconds
    guard CMTimeCompare(scrubChaseTime, target) != 0 else { return }
    scrubChaseTime = target
    timelinePreview.show(at: target.seconds)
  }

  private func scheduleInteractiveScrubSeek(delay: Duration = .milliseconds(33)) {
    guard !scrubSeekInProgress, scrubDispatchTask == nil else { return }
    let generation = scrubGeneration
    // Coalesce finger events and leave a display refresh between decoded frames.
    // Never cancel/restart a decoder seek on every touch event (Apple QA1820).
    scrubDispatchTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, self.scrubGeneration == generation else { return }
      self.scrubDispatchTask = nil
      self.performInteractiveScrubSeek()
    }
  }

  func endInteractiveScrub(to seconds: Double, resumeAfter: Bool) {
    timelinePreview.end(keepImageUntilSeekCompletes: true)
    let target = CMTime(seconds: clampedSeekTarget(seconds), preferredTimescale: 600)
    currentTime = target.seconds
    scrubChaseTime = target
    scrubFinalTarget = target
    scrubResumeAfterFinish = resumeAfter
    scrubDispatchTask?.cancel()
    scrubDispatchTask = nil

    if scrubSeekInProgress {
      if CMTimeCompare(scrubInFlightTarget, target) == 0 {
        // Let the matching preview finish; refine only if it lands too far away.
        isInteractiveScrubLoading = true
        return
      }
      // Once on release, abandon an obsolete network seek so it cannot hold up
      // the committed target. Its completion must not restart the old chase.
      scrubGeneration &+= 1
      player.currentItem?.cancelPendingSeeks()
      scrubSeekInProgress = false
    } else if abs(player.currentTime().seconds - target.seconds) <= 0.12 {
      finishInteractiveScrub()
      return
    }
    performInteractiveScrubSeek()
  }

  private func performInteractiveScrubSeek() {
    guard interactiveScrubActive, scrubChaseTime.isValid else { return }
    guard let item = player.currentItem else {
      finishInteractiveScrub()
      return
    }
    guard item.status == .readyToPlay else {
      if item.status == .unknown {
        scheduleInteractiveScrubSeek(delay: .milliseconds(100))
      } else {
        finishInteractiveScrub()
      }
      return
    }
    let target = scrubChaseTime
    let generation = scrubGeneration
    let isFinalPass = scrubFinalTarget != nil
    // Tiny tolerances force a GOP decode even for already-buffered data.
    // AVPlayer's fast path finds a nearby decodable frame while dragging.
    let tolerance = isFinalPass ? CMTime(seconds: 0.10, preferredTimescale: 600) : .positiveInfinity
    scrubSeekInProgress = true
    scrubInFlightTarget = target
    isInteractiveScrubLoading = isFinalPass
    player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
      Task { @MainActor in
        guard let self, self.scrubGeneration == generation, self.player.currentItem === item else { return }
        self.scrubSeekInProgress = false
        if CMTimeCompare(self.scrubChaseTime, target) != 0 {
          if self.scrubFinalTarget != nil { self.performInteractiveScrubSeek() }
          else { self.scheduleInteractiveScrubSeek() }
          return
        }
        if let final = self.scrubFinalTarget {
          if finished, !isFinalPass, abs(self.player.currentTime().seconds - final.seconds) > 0.12 {
            self.performInteractiveScrubSeek()
          } else {
            self.finishInteractiveScrub()
          }
        } else {
          self.isInteractiveScrubLoading = false
        }
      }
    }
  }

  private func finishInteractiveScrub() {
    timelinePreview.end()
    scrubSeekInProgress = false
    scrubFinalTarget = nil
    interactiveScrubActive = false
    isInteractiveScrubLoading = false
    let landed = player.currentTime().seconds
    if landed.isFinite { currentTime = max(landed, 0) }
    lastPlaybackProgressAt = Date()
    lastPlaybackProgressTime = currentTime
    let shouldResume = scrubResumeAfterFinish
    scrubResumeAfterFinish = false
    if shouldResume {
      player.play()
      isPlaying = true
      isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
  }

  private func cancelInteractiveScrub() {
    timelinePreview.end()
    scrubGeneration &+= 1
    scrubDispatchTask?.cancel()
    scrubDispatchTask = nil
    if scrubSeekInProgress { player.currentItem?.cancelPendingSeeks() }
    scrubSeekInProgress = false
    scrubFinalTarget = nil
    scrubResumeAfterFinish = false
    interactiveScrubActive = false
    isInteractiveScrubLoading = false
  }

  private func clampedSeekTarget(_ seconds: Double) -> Double {
    let upper = duration > 0 ? duration : max(seconds, currentTime + 60)
    return min(max(seconds, 0), upper)
  }

  func seekBy(_ delta: Double) {
    seek(to: currentTime + delta)
  }

  func setPlaybackRate(_ rate: Float) {
    let safeRate = min(max(rate, 0.5), 2.0)
    player.defaultRate = safeRate
    if player.timeControlStatus == .playing { player.rate = safeRate }
  }

  func setVolume(_ value: Float) { player.volume = min(max(value, 0), 1) }

  func selectAudio(_ id: String?) {
    guard let playerItem = player.currentItem, let audioGroup else { return }
    player.appliesMediaSelectionCriteriaAutomatically = false
    if let id, let mediaOption = audioOptions.first(where: { $0.id == id }) {
      playerItem.select(mediaOption.option, in: audioGroup)
      selectedAudioOptionID = id
    } else {
      playerItem.selectMediaOptionAutomatically(in: audioGroup)
      selectedAudioOptionID = nil
    }
  }

  func selectSubtitle(_ id: String?) {
    guard let playerItem = player.currentItem, let subtitleGroup else { return }
    player.appliesMediaSelectionCriteriaAutomatically = false
    if let id, let mediaOption = subtitleOptions.first(where: { $0.id == id }) {
      playerItem.select(mediaOption.option, in: subtitleGroup)
      selectedSubtitleOptionID = id
    } else {
      playerItem.select(nil, in: subtitleGroup)
      selectedSubtitleOptionID = nil
    }
  }

  var bestTranscode: VideoSource? {
    sources.filter { !$0.isOriginal }.max { $0.definition < $1.definition }
  }

  var original: VideoSource? {
    sources.first(where: \.isOriginal)
  }

  var progress: Double {
    guard duration > 0 else { return 0 }
    return min(max(currentTime / duration, 0), 1)
  }

  var bufferProgress: Double {
    guard duration > 0 else { return 0 }
    return min(max(bufferedUntil / duration, 0), 1)
  }

  var bufferedDuration: Double {
    max(PlaybackBufferPolicy.contiguousEnd(at: currentTime, ranges: bufferedRanges) - currentTime, 0)
  }

  private func play(_ source: VideoSource, allowFallback: Bool, resumeAt: Double? = nil) async {
    rangeCache?.stop()
    rangeCache = nil
    diskBufferedMegabytes = 0
    playbackTransport = "直连"
    cancelInteractiveScrub()
    bufferedRanges = []
    bufferedUntil = 0
    selectedSource = source
    hasPlayedCurrentItem = false
    pendingInitialPosition = resumeAt ?? libraryStore.resumePosition(for: item)
    engineSwitchReason = nil
    engineSwitchResumePosition = nil
    bufferingStartedAt = nil
    countedCurrentStall = false
    sustainedStalls = []
    bufferStallCount = 0
    preferredBufferSeconds = 0
    wantsPlayback = true
    errorMessage = nil
    didReachEnd = false
    isBuffering = true
    requiresVLC = false
    videoDisplaySize = nil
    videoCodec = "读取中"
    hdrFormat = "SDR"
    nominalFrameRate = 0
    chapters = []
    timelinePreview.reset()
    mediaInfoGeneration = UUID()
    activeAsset = nil
    audioOptions = []
    subtitleOptions = []
    audioGroup = nil
    subtitleGroup = nil
    selectedAudioOptionID = nil
    selectedSubtitleOptionID = nil
    networkMbps = 0
    transferredMegabytes = 0
    lastTransferredBytes = 0
    lastBandwidthSampleAt = Date()
    lastPlaybackProgressAt = Date()
    lastPlaybackProgressTime = 0
    interactiveScrubActive = false
    stallProbeTask?.cancel()
    stallProbeTask = nil
    lastStallRecoveryAt = .distantPast
    player.automaticallyWaitsToMinimizeStalling = true

    // Containers that AVPlayer commonly rejects should go straight to VLC when
    // the VLC runtime is actually bundled. MP4/MOV and other Apple-friendly
    // originals still stay on AVPlayer so HDR, Dolby Vision, AirPlay and PiP
    // keep using the system playback pipeline.
    if source.isOriginal, originalPlaybackEngine != .system,
      (item.prefersVLCForOriginal || originalPlaybackEngine == .vlc), VLCAvailability.isAvailable {
      player.replaceCurrentItem(with: nil)
      requiresVLC = true
      isPlaying = false
      isBuffering = false
      videoCodec = item.fileExtension.uppercased()
      hdrFormat = "由 VLC 解码"
      return
    }

    var assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
    if !source.headers.isEmpty { assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = source.headers }
    let asset: AVURLAsset
    let airPlay = player.isExternalPlaybackActive || AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    if !bypassRangeCache, !airPlay,
      PlaybackRangeCache.supports(source: source, fileExtension: item.fileExtension),
      let cache = PlaybackRangeCache(source: source, fileExtension: item.fileExtension) {
      rangeCache = cache
      asset = cache.makeAsset()
      playbackTransport = "分段磁盘缓存"
    } else {
      asset = AVURLAsset(url: source.url, options: assetOptions)
    }
    activeAsset = asset

    // Keep first-frame startup lean: AVPlayerItem(asset:) implicitly asks the
    // asset to load duration before the item becomes ready. Cineva already
    // loads duration/tracks asynchronously after playback starts, so avoid
    // duplicating that work on the critical startup path.
    let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [])
    // Startup uses a small runway; once frames advance we grow it using the
    // stream bitrate. Do not force an almost-empty buffer to play immediately.
    playerItem.preferredForwardBufferDuration = fastStartEnabled ? 8 : 15

    // Maximum-fidelity policy with no extra decode/filter stage. A zero bit-rate
    // or resolution value means "no cap" for adaptive/HLS assets, including on
    // expensive networks. Direct OpenList files remain byte-for-byte originals.
    playerItem.preferredPeakBitRate = 0
    playerItem.preferredMaximumResolution = .zero
    playerItem.preferredPeakBitRateForExpensiveNetworks = 0
    playerItem.preferredMaximumResolutionForExpensiveNetworks = .zero

    // Preserve dynamic HDR metadata when the source/device supports it. This
    // stays on AVFoundation's native hardware presentation path and does not add
    // a custom video compositor, so PiP/AirPlay/fast start remain untouched.
    playerItem.appliesPerFrameHDRDisplayMetadata = true
    installItemObservers(for: playerItem)
    player.replaceCurrentItem(with: playerItem)

    let resumePosition = pendingInitialPosition
    if resumePosition > 0, resumeAt != nil || (resumePosition > 2 && (duration <= 0 || resumePosition < duration - 15)) {
      currentTime = resumePosition
      player.seek(
        to: CMTime(seconds: resumePosition, preferredTimescale: 600),
        toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
        toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
      ) { _ in }
    } else {
      currentTime = 0
    }
    player.play()
    configureTimelinePreviewSource()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

    let generation = mediaInfoGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      // In fast-start mode, give AVPlayer a short head start before asking the
      // same remote asset for duration/tracks/chapters. Those inspections can
      // otherwise compete with the first media ranges on slower OpenList links.
      if self.fastStartEnabled {
        try? await Task.sleep(nanoseconds: 900_000_000)
      }
      guard self.mediaInfoGeneration == generation, self.player.currentItem === playerItem else { return }
      async let durationTask = try? asset.load(.duration)
      async let characteristicsTask = self.detectVideoCharacteristics(asset)
      async let selectionTask: Void = self.loadMediaSelectionOptions(asset: asset, playerItem: playerItem)
      async let chapterTask = self.loadChapters(asset: asset)

      if let loadedDuration = await durationTask, loadedDuration.seconds.isFinite, loadedDuration.seconds > 0, self.mediaInfoGeneration == generation {
        self.duration = loadedDuration.seconds
      }
      let characteristics = await characteristicsTask
      guard self.mediaInfoGeneration == generation, self.player.currentItem === playerItem else { return }
      self.videoDisplaySize = characteristics.size
      self.videoCodec = characteristics.codec
      self.hdrFormat = characteristics.hdr
      self.nominalFrameRate = characteristics.frameRate
      _ = await selectionTask
      let chapters = await chapterTask
      if self.mediaInfoGeneration == generation { self.chapters = chapters }
    }
  }

  private func configureTimelinePreviewSource() {
    guard !requiresVLC, let activeAsset else { return }
    // Small transcodes are previews only; the selected playback quality stays
    // original. Never scan the entire remote original to prepare thumbnails.
    let lightSource = sources.filter { !$0.isOriginal && (1...3).contains($0.definition) }
      .min { $0.definition < $1.definition }
    if let source = lightSource {
      var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
      if !source.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers }
      timelinePreview.configure(asset: AVURLAsset(url: source.url, options: options),
        identity: source.id, allowsWarmup: false, fallbackAsset: activeAsset)
    } else {
      timelinePreview.configure(asset: activeAsset, identity: selectedSource?.id ?? "",
        allowsWarmup: activeAsset.url.isFileURL)
    }
  }

  private func loadChapters(asset: AVAsset) async -> [PlayerChapter] {
    guard let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty else { return [] }
    let groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: locales.map(\.identifier))
    return groups.enumerated().compactMap { index, group in
      let start = group.timeRange.start.seconds
      let end = CMTimeRangeGetEnd(group.timeRange).seconds
      guard start.isFinite, end.isFinite, end > start else { return nil }
      let titleItem = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
      let title = titleItem?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      return PlayerChapter(id: "chapter-\(index)-\(start)", title: title?.isEmpty == false ? title! : "章节 \(index + 1)", start: start, end: end)
    }
  }

  private func detectVideoCharacteristics(_ asset: AVAsset) async -> (
    size: CGSize?, codec: String, hdr: String, frameRate: Float
  ) {
    guard let tracks = try? await asset.loadTracks(withMediaType: .video),
      let track = tracks.first
    else {
      return (nil, "未知", "SDR", 0)
    }

    var displaySize: CGSize?
    if let naturalSize = try? await track.load(.naturalSize),
      let preferredTransform = try? await track.load(.preferredTransform)
    {
      let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
      let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
      if size.width > 0, size.height > 0 { displaySize = size }
    }

    var codec = "未知"
    var codecFourCC = ""
    var hasDolbyVisionConfiguration = false
    if let descriptions = try? await track.load(.formatDescriptions),
      let first = descriptions.first
    {
      codecFourCC = fourCCString(CMFormatDescriptionGetMediaSubType(first))
      codec = friendlyCodecName(codecFourCC)

      // Dolby Vision Profile 8.4 commonly uses an hvc1 sample entry. Detect the
      // dvcC/dvvC configuration atoms instead of relying only on a dvh1/dvhe FourCC.
      if let atoms = CMFormatDescriptionGetExtension(
        first,
        extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
      ) as? NSDictionary {
        hasDolbyVisionConfiguration = atoms["dvvC"] != nil || atoms["dvcC"] != nil
      }
    }

    let mediaCharacteristics = (try? await track.load(.mediaCharacteristics)) ?? []
    let containsHDR = mediaCharacteristics.contains(.containsHDRVideo)
    let normalized = codecFourCC.lowercased()
    let hdr: String
    if hasDolbyVisionConfiguration || normalized == "dvh1" || normalized == "dvhe" {
      hdr = "Dolby Vision"
      if codec == "HEVC" { codec = "HEVC · Dolby Vision" }
    } else if containsHDR {
      hdr = "HDR"
    } else {
      hdr = "SDR"
    }

    let frameRate = (try? await track.load(.nominalFrameRate)) ?? 0
    return (displaySize, codec, hdr, frameRate)
  }

  private func fourCCString(_ value: FourCharCode) -> String {
    let bytes: [CChar] = [
      CChar((value >> 24) & 0xff),
      CChar((value >> 16) & 0xff),
      CChar((value >> 8) & 0xff),
      CChar(value & 0xff),
      0,
    ]
    return String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func friendlyCodecName(_ fourCC: String) -> String {
    switch fourCC.lowercased() {
    case "avc1", "avc3": return "H.264"
    case "hvc1", "hev1": return "HEVC"
    case "dvh1", "dvhe": return "HEVC · Dolby Vision"
    case "av01": return "AV1"
    case "vp09": return "VP9"
    default: return fourCC.isEmpty ? "未知" : fourCC.uppercased()
    }
  }

  private func loadMediaSelectionOptions(asset: AVAsset, playerItem: AVPlayerItem) async {
    async let loadedAudioGroup = try? asset.loadMediaSelectionGroup(for: .audible)
    async let loadedSubtitleGroup = try? asset.loadMediaSelectionGroup(for: .legible)

    let (audio, subtitles) = await (loadedAudioGroup, loadedSubtitleGroup)
    audioGroup = audio
    subtitleGroup = subtitles

    if let audio {
      audioOptions = audio.options.enumerated().map { index, option in
        PlayerMediaOption(id: "audio-\(index)-\(option.displayName)", title: option.displayName, option: option)
      }
      if let selected = playerItem.currentMediaSelection.selectedMediaOption(in: audio),
        let index = audio.options.firstIndex(of: selected)
      {
        selectedAudioOptionID = audioOptions[safe: index]?.id
      }
    }

    if let subtitles {
      subtitleOptions = subtitles.options.enumerated().map { index, option in
        PlayerMediaOption(id: "subtitle-\(index)-\(option.displayName)", title: option.displayName, option: option)
      }
      if let selected = playerItem.currentMediaSelection.selectedMediaOption(in: subtitles),
        let index = subtitles.options.firstIndex(of: selected)
      {
        selectedSubtitleOptionID = subtitleOptions[safe: index]?.id
      }
    }
  }

  private func installTimeObserverIfNeeded() {
    guard playbackTimer == nil else { return }
    // Playback-time observers stop ticking when the media clock stalls. The
    // watchdog and buffer display must keep running on wall time, including
    // while the user is dragging or waiting for a remote range to arrive.
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.pollPlayback() }
    }
    timer.tolerance = 0.08
    RunLoop.main.add(timer, forMode: .common)
    playbackTimer = timer
  }

  private func pollPlayback() {
    guard !requiresVLC else { return }
    if let failedItem = player.currentItem, failedItem.status == .failed {
      if recoverRangeCacheIfNeeded() { return }
      if selectedSource?.isOriginal == true, originalPlaybackEngine != .system, VLCAvailability.isAvailable {
        switchOriginalToVLC(reason: "系统内核无法打开原画，已切换 VLC")
      } else {
        errorMessage = failedItem.error?.localizedDescription ?? "视频无法打开。"
        wantsPlayback = false
      }
      return
    }
    let seconds = player.currentTime().seconds.isFinite ? max(player.currentTime().seconds, 0) : 0
    let now = Date()
    // A backwards seek also establishes a new progress baseline. Otherwise
    // playback appears stalled until it reaches the old pre-seek timestamp.
    let progressed = abs(seconds - lastPlaybackProgressTime) > 0.08
    if progressed {
      lastPlaybackProgressTime = seconds
      lastPlaybackProgressAt = now
      if seconds > 0 { hasPlayedCurrentItem = true }
    }

    if !interactiveScrubActive {
      currentTime = seconds
      isPlaying = player.timeControlStatus == .playing
      isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    if networkAutoRecoveryEnabled,
      wantsPlayback,
      !didReachEnd,
      !interactiveScrubActive,
      seconds > 0.5,
      now.timeIntervalSince(lastPlaybackProgressAt) > 3.2,
      (player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.rate > 0)
    {
      requestStallRecoveryIfNeeded()
    }

    let ranges = PlaybackBufferPolicy.normalized((player.currentItem?.loadedTimeRanges ?? []).map {
      let range = $0.timeRangeValue
      return PlaybackBufferRange(start: range.start.seconds, end: CMTimeRangeGetEnd(range).seconds)
    })
    if ranges != bufferedRanges { bufferedRanges = ranges }
    bufferedUntil = PlaybackBufferPolicy.contiguousEnd(at: currentTime, ranges: ranges)
    updateForwardBuffer()
    timelinePreview.maintain(duration: duration,
      mayWarm: wantsPlayback && isPlaying && !isBuffering && !interactiveScrubActive
        && bufferedDuration >= 20 && !player.isExternalPlaybackActive)

    if let cache = rangeCache {
      let counters = cache.counters
      diskBufferedMegabytes = Double(counters.disk) / 1_048_576
      sampleNetwork(bytes: counters.network, now: now)
    } else if let log = player.currentItem?.accessLog() {
      let bytes = log.events.reduce(Int64(0)) { $0 + max($1.numberOfBytesTransferred, 0) }
      sampleNetwork(bytes: bytes, now: now)
    } else {
      networkMbps = 0
    }
    updateWaitingStatusAndFallback(now: now)
    guard !requiresVLC else { return }

    let second = Int(seconds)
    if second >= 0, second != lastSavedSecond, second % 5 == 0 {
      lastSavedSecond = second
      saveProgress(force: false)
    }
  }

  private func sampleNetwork(bytes: Int64, now: Date) {
    transferredMegabytes = Double(bytes) / 1_048_576
    let elapsed = now.timeIntervalSince(lastBandwidthSampleAt)
    if elapsed >= 0.45 {
      networkMbps = bytes >= lastTransferredBytes
        ? Double(bytes - lastTransferredBytes) * 8 / elapsed / 1_000_000 : 0
      lastTransferredBytes = bytes
      lastBandwidthSampleAt = now
    }
  }

  private func updateForwardBuffer() {
    guard hasPlayedCurrentItem, let playerItem = player.currentItem else { return }
    let indicated = playerItem.accessLog()?.events.last?.indicatedBitrate ?? 0
    let originalEstimate = selectedSource?.isOriginal == true && duration > 0
      ? Double(item.size) * 8 / duration : 0
    let bitrate = max(indicated.isFinite ? indicated : 0, originalEstimate)
    let target = PlaybackBufferPolicy.forwardDuration(bitrate: bitrate,
      stalls: bufferStallCount, rate: Double(player.defaultRate),
      memoryBytes: ProcessInfo.processInfo.physicalMemory)
    guard abs(target - preferredBufferSeconds) >= 2 else { return }
    preferredBufferSeconds = target
    playerItem.preferredForwardBufferDuration = target
  }

  private func updateWaitingStatusAndFallback(now: Date) {
    guard wantsPlayback, !interactiveScrubActive, !didReachEnd else {
      bufferingStartedAt = nil
      countedCurrentStall = false
      waitingStatus = interactiveScrubActive ? "正在定位" : "已暂停"
      return
    }
    let stalled = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      || (player.currentItem?.status == .readyToPlay && now.timeIntervalSince(lastPlaybackProgressAt) > 3)
    guard stalled else {
      bufferingStartedAt = nil
      countedCurrentStall = false
      waitingStatus = "正在播放"
      return
    }
    isBuffering = true
    if player.reasonForWaitingToPlay == .toMinimizeStalls {
      waitingStatus = bufferedDuration > 0 ? "系统正在评估缓冲" : "正在等待视频数据"
    } else {
      waitingStatus = "正在等待视频数据或解码"
    }
    if bufferingStartedAt == nil { bufferingStartedAt = now }
    let wait = now.timeIntervalSince(bufferingStartedAt ?? now)
    if wait >= 8, recoverRangeCacheIfNeeded() { return }
    sustainedStalls.removeAll { now.timeIntervalSince($0) > 60 }
    if wait >= 1, !countedCurrentStall {
      countedCurrentStall = true
      bufferStallCount = min(bufferStallCount + 1, 3)
      updateForwardBuffer()
    }
    // Short refills grow the buffer too, but only sustained stalls trigger an
    // engine handoff. Count a continuous stall once at the three-second mark.
    if wait >= 3, sustainedStalls.last.map({ $0 < (bufferingStartedAt ?? now) }) ?? true {
      sustainedStalls.append(now)
    }
    // A single normal refill must not change engines. Recover only a long
    // interruption or repeated sustained stalls, and never downgrade quality.
    guard networkAutoRecoveryEnabled, allowsAutomaticEngineSwitch, originalPlaybackEngine == .automatic,
      selectedSource?.isOriginal == true, !player.isExternalPlaybackActive,
      wait >= 15 || sustainedStalls.count >= 3 else { return }
    switchOriginalToVLC(reason: "原画持续缓冲，已切换 VLC 续播")
  }

  private func switchOriginalToVLC(reason: String) {
    guard !requiresVLC, selectedSource?.isOriginal == true, VLCAvailability.isAvailable else { return }
    let position = player.currentTime().seconds
    engineSwitchResumePosition = position.isFinite && position > 0 ? position
      : (hasPlayedCurrentItem ? currentTime : pendingInitialPosition)
    libraryStore.recordPlayback(item, position: engineSwitchResumePosition ?? 0, duration: duration)
    engineSwitchReason = reason
    waitingStatus = reason
    cancelInteractiveScrub()
    stallProbeTask?.cancel()
    stallProbeTask = nil
    wantsPlayback = false
    player.pause()
    player.replaceCurrentItem(with: nil)
    rangeCache?.stop()
    rangeCache = nil
    // Invalidate metadata tasks from the old AVPlayerItem.
    mediaInfoGeneration = UUID()
    activeAsset = nil
    requiresVLC = true
    isPlaying = false
    isBuffering = false
    errorMessage = nil
  }

  /// Cache transport errors must not strand playback or cause a quality change.
  /// The signed source, selected quality, playback rate and position are kept.
  @discardableResult
  private func recoverRangeCacheIfNeeded() -> Bool {
    guard rangeCache != nil else { return false }
    if switchingCacheTransport { return true }
    switchingCacheTransport = true
    let shouldResume = wantsPlayback
    let position = max(currentTime, hasPlayedCurrentItem ? 0 : pendingInitialPosition)
    let generation = mediaInfoGeneration
    bypassRangeCache = true
    timelinePreview.reset()
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.switchingCacheTransport = false }
      guard self.mediaInfoGeneration == generation, let source = self.selectedSource else { return }
      await self.play(source, allowFallback: false, resumeAt: position)
      if !shouldResume { self.pause() }
    }
    return true
  }

  func prepareForExternalPlayback() {
    // A remote AirPlay receiver cannot resolve our in-process resource loader.
    // Switch to the original URL before displaying the route picker.
    _ = recoverRangeCacheIfNeeded()
  }

  func stop() {
    pause()
    deferredSourcesTask?.cancel()
    mediaInfoGeneration = UUID()
    timelinePreview.reset()
    player.replaceCurrentItem(with: nil)
    activeAsset = nil
    rangeCache?.stop()
    rangeCache = nil
    playbackTimer?.invalidate()
    playbackTimer = nil
  }

  private func installItemObservers(for playerItem: AVPlayerItem) {
    if let failureObserver {
      NotificationCenter.default.removeObserver(failureObserver)
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    if let stallObserver {
      NotificationCenter.default.removeObserver(stallObserver)
    }

    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      Task { @MainActor in
        guard self.player.currentItem === playerItem else { return }
        if self.recoverRangeCacheIfNeeded() { return }
        await self.handlePlaybackFailure(notification)
      }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === playerItem else { return }
        self.currentTime = self.duration
        self.isPlaying = false
        self.didReachEnd = true
        self.wantsPlayback = false
        self.stallProbeTask?.cancel()
        self.saveProgress(force: true)
      }
    }

    stallObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === playerItem else { return }
        self.requestStallRecoveryIfNeeded()
      }
    }
  }

  private func requestStallRecoveryIfNeeded() {
    guard networkAutoRecoveryEnabled, wantsPlayback, !didReachEnd, !interactiveScrubActive else { return }
    guard let playerItem = player.currentItem, playerItem.status == .readyToPlay else { return }
    guard stallProbeTask == nil else { return }
    let now = Date()
    guard now.timeIntervalSince(lastStallRecoveryAt) > 8 else { return }

    lastStallRecoveryAt = now
    isBuffering = true
    let generation = mediaInfoGeneration
    let stalledAt = max(player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime, 0)

    // A stall is normally a legitimate buffer refill, not a broken timeline.
    // Let the native loader continue. Seeking after 950 ms can restart range /
    // segment requests; playImmediately can consume the tiny refill again.
    player.automaticallyWaitsToMinimizeStalling = true
    stallProbeTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, !Task.isCancelled, self.mediaInfoGeneration == generation else { return }
      self.stallProbeTask = nil
      guard self.wantsPlayback, !self.didReachEnd, !self.interactiveScrubActive,
        self.player.currentItem === playerItem else { return }

      let nowTime = max(self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : self.currentTime, 0)
      if nowTime > stalledAt + 0.12 {
        self.lastPlaybackProgressAt = Date()
        self.lastPlaybackProgressTime = nowTime
        self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        return
      }

      // Only reassert play when the buffer is ready. Never cancel a pending
      // download or force playback against AVPlayer's insufficient-data signal.
      guard !playerItem.isPlaybackBufferEmpty,
        playerItem.isPlaybackLikelyToKeepUp || playerItem.isPlaybackBufferFull else { return }
      self.player.play()
      self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
  }

  private func handlePlaybackFailure(_ notification: Notification) async {
    guard !isFallingBack else { return }
    let reason = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
      .localizedDescription
    if selectedSource?.isOriginal == true, originalPlaybackEngine != .system, VLCAvailability.isAvailable {
      switchOriginalToVLC(reason: "系统内核无法继续播放，已切换 VLC 原画")
    } else if selectedSource?.isOriginal == true, let fallback = bestTranscode {
      isFallingBack = true
      didFallbackFromOriginal = true
      await play(fallback, allowFallback: false)
      isFallingBack = false
    } else {
      errorMessage = reason ?? "视频播放失败。"
    }
  }

  private func configureAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
    } catch {
      // Non-fatal. Playback can still proceed on self-signed builds.
    }
  }

  private func activateAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {}
  }

  private func installAudioSessionObservers() {
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      Task { @MainActor [weak self] in
        guard let self,
          let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
          self.pause()
        case .ended:
          let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
          let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
          if options.contains(.shouldResume) {
            self.activateAudioSession()
            self.resume()
          }
        @unknown default:
          break
        }
      }
    }

    routeChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      Task { @MainActor [weak self] in
        guard let self,
          let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        if AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay }) {
          self.prepareForExternalPlayback()
        }
        if reason == .oldDeviceUnavailable {
          self.pause()
        }
      }
    }
  }

  private func saveProgress(force: Bool) {
    guard hasPlayedCurrentItem else { return }
    let seconds = player.currentTime().seconds
    guard seconds.isFinite, seconds >= 0 else { return }
    libraryStore.recordPlayback(item, position: seconds, duration: duration)
    let second = Int(seconds)
    let shouldSyncRemote = force || second - lastRemoteHistorySecond >= 60
    if shouldSyncRemote {
      lastRemoteHistorySecond = second
      Task {
        await api.updateVideoHistory(
          pickCode: item.pickCode,
          seconds: second,
          watchEnd: duration > 0 && seconds >= duration - 10
        )
      }
    }
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
