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
  private(set) var isPlaying = false
  private(set) var didReachEnd = false
  private(set) var isBuffering = false
  private(set) var videoDisplaySize: CGSize?
  private(set) var audioOptions: [PlayerMediaOption] = []
  private(set) var subtitleOptions: [PlayerMediaOption] = []
  private(set) var selectedAudioOptionID: String?
  private(set) var selectedSubtitleOptionID: String?
  private(set) var networkMbps: Double = 0
  private(set) var transferredMegabytes: Double = 0
  private(set) var requiresVLC = false
  private(set) var videoCodec = "读取中"
  private(set) var hdrFormat = "SDR"
  private(set) var nominalFrameRate: Float = 0
  private(set) var chapters: [PlayerChapter] = []

  var errorMessage: String?
  var didFallbackFromOriginal = false

  let player = AVPlayer()
  var volume: Float { player.volume }

  private let item: CloudItem
  private let api: APIClient
  private let libraryStore: LibraryStore
  private let defaultQuality: AppState.DefaultQuality
  private let fastStartEnabled: Bool
  private let networkAutoRecoveryEnabled: Bool
  private var activeAsset: AVURLAsset?
  private var previewCache: [Int: UIImage] = [:]
  private var mediaInfoGeneration = UUID()
  private var audioGroup: AVMediaSelectionGroup?
  private var subtitleGroup: AVMediaSelectionGroup?
  nonisolated(unsafe) private var timeObserver: Any?
  nonisolated(unsafe) private var failureObserver: NSObjectProtocol?
  nonisolated(unsafe) private var endObserver: NSObjectProtocol?
  nonisolated(unsafe) private var stallObserver: NSObjectProtocol?
  nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
  nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
  private var lastSavedSecond = -1
  private var lastRemoteHistorySecond = -60
  private var isFallingBack = false
  private var lastTransferredBytes: Int64 = 0
  private var lastBandwidthSampleAt = Date()
  private var lastStallRecoveryAt = Date.distantPast

  // Interactive timeline scrubbing uses a single in-flight AVPlayer seek. While
  // that seek is running, finger movement only updates `scrubChaseTime`; when
  // the current seek completes we immediately chase the newest target. This
  // avoids flooding AVPlayer / a remote Range source with overlapping seeks.
  private var scrubSeekInProgress = false
  private var scrubChaseTime: CMTime = .invalid
  private var scrubFinalTarget: CMTime?
  private var scrubResumeAfterFinish = false
  private var scrubLiveToleranceSeconds: Double = 0.10
  private var scrubGeneration = 0

  init(
    item: CloudItem, api: APIClient, libraryStore: LibraryStore,
    defaultQuality: AppState.DefaultQuality,
    fastStartEnabled: Bool = true,
    networkAutoRecoveryEnabled: Bool = true
  ) {
    self.item = item
    self.api = api
    self.libraryStore = libraryStore
    self.defaultQuality = defaultQuality
    self.fastStartEnabled = fastStartEnabled
    self.networkAutoRecoveryEnabled = networkAutoRecoveryEnabled
    self.duration = max(item.duration, libraryStore.knownDuration(for: item))
    player.automaticallyWaitsToMinimizeStalling = !fastStartEnabled
    player.allowsExternalPlayback = true
    configureAudioSession()
    installAudioSessionObservers()
  }

  deinit {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
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
    guard !isPreparing else { return }
    activateAudioSession()
    isPreparing = true
    didReachEnd = false
    defer { isPreparing = false }

    do {
      sources = try await api.videoSources(for: item)
      guard !sources.isEmpty else {
        errorMessage = "媒体源没有返回可播放地址。"
        return
      }

      let preferred: VideoSource?
      switch defaultQuality {
      case .highestTranscode:
        preferred = bestTranscode ?? original ?? sources.first
      case .original:
        preferred = original ?? bestTranscode ?? sources.first
      }
      if let preferred {
        await play(preferred, allowFallback: true)
      }
      installTimeObserverIfNeeded()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func select(_ source: VideoSource) async {
    didFallbackFromOriginal = false
    await play(source, allowFallback: true)
  }

  func pause() {
    player.pause()
    isPlaying = false
    isBuffering = false
    saveProgress(force: true)
  }

  func resume() {
    didReachEnd = false
    activateAudioSession()
    player.play()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }

  func replayFromStart() {
    didReachEnd = false
    currentTime = 0
    bufferedUntil = max(bufferedUntil, 0)
    player.seek(to: .zero)
    player.playImmediately(atRate: player.defaultRate)
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
    let target = clampedSeekTarget(seconds)
    currentTime = target
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
  }

  /// Starts a photo-style interactive scrub and returns whether playback should
  /// resume when the user's finger leaves the timeline. Pausing here prevents
  /// playback progression from fighting the seek chase while the thumb moves.
  @discardableResult
  func beginInteractiveScrub() -> Bool {
    let shouldResume = player.timeControlStatus == .playing || player.rate > 0
    if shouldResume { player.pause() }
    isPlaying = false
    isBuffering = false
    scrubFinalTarget = nil
    scrubResumeAfterFinish = false
    scrubLiveToleranceSeconds = 0.08
    scrubGeneration &+= 1
    player.currentItem?.cancelPendingSeeks()
    scrubSeekInProgress = false
    scrubChaseTime = .invalid
    return shouldResume
  }

  /// Updates the visible video frame while the timeline is being dragged. Only
  /// one AVPlayer seek is allowed to be in flight; fast finger motion simply
  /// replaces the chase target. A small tolerance lets streamed media snap to a
  /// nearby decodable sample instead of doing an expensive exact-frame decode
  /// for every pixel of movement.
  func interactiveScrub(to seconds: Double) {
    let target = clampedSeekTarget(seconds)
    currentTime = target

    // Adapt tolerance to finger speed in timeline-space. Large jumps should
    // land on a nearby decodable frame immediately; fine movements tighten the
    // tolerance so slow scrubbing still feels precise. The release pass below
    // always performs a near-frame-accurate commit.
    if scrubChaseTime.isValid {
      let previous = scrubChaseTime.seconds
      if previous.isFinite {
        let delta = abs(target - previous)
        switch delta {
        case 12...: scrubLiveToleranceSeconds = 0.42
        case 4..<12: scrubLiveToleranceSeconds = 0.24
        case 1..<4: scrubLiveToleranceSeconds = 0.12
        case 0.25..<1: scrubLiveToleranceSeconds = 0.065
        default: scrubLiveToleranceSeconds = 0.035
        }
      }
    } else {
      scrubLiveToleranceSeconds = 0.08
    }

    scrubChaseTime = CMTime(seconds: target, preferredTimescale: 600)
    scrubFinalTarget = nil
    if !scrubSeekInProgress { performInteractiveScrubSeek() }
  }

  /// Commits the final scrub position with near-frame precision, then restores
  /// the previous play/pause state only after that final seek has landed.
  func endInteractiveScrub(to seconds: Double, resumeAfter: Bool) {
    let target = clampedSeekTarget(seconds)
    currentTime = target
    let time = CMTime(seconds: target, preferredTimescale: 600)
    scrubChaseTime = time
    scrubFinalTarget = time
    scrubResumeAfterFinish = resumeAfter
    if !scrubSeekInProgress { performInteractiveScrubSeek() }
  }

  private func performInteractiveScrubSeek() {
    guard scrubChaseTime.isValid, let item = player.currentItem, item.status == .readyToPlay else {
      scrubSeekInProgress = false
      if scrubResumeAfterFinish {
        scrubResumeAfterFinish = false
        player.playImmediately(atRate: player.defaultRate)
        isPlaying = true
      }
      return
    }

    let target = scrubChaseTime
    let generation = scrubGeneration
    let isFinalPass = scrubFinalTarget.map { CMTimeCompare($0, target) == 0 } ?? false
    let toleranceSeconds = isFinalPass ? (1.0 / 120.0) : scrubLiveToleranceSeconds
    let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
    scrubSeekInProgress = true

    player.seek(
      to: target,
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.scrubGeneration == generation else { return }

        // The finger moved while this seek was decoding. Skip all stale targets
        // and immediately chase the newest one.
        if CMTimeCompare(self.scrubChaseTime, target) != 0 {
          self.performInteractiveScrubSeek()
          return
        }

        // If the drag ended while a loose live seek to the same target was in
        // flight, do one final tighter pass before resuming playback.
        if let final = self.scrubFinalTarget,
          CMTimeCompare(final, target) == 0,
          !isFinalPass
        {
          self.performInteractiveScrubSeek()
          return
        }

        self.scrubSeekInProgress = false
        if let final = self.scrubFinalTarget, CMTimeCompare(final, target) == 0 {
          self.scrubFinalTarget = nil
          let shouldResume = self.scrubResumeAfterFinish
          self.scrubResumeAfterFinish = false
          if shouldResume {
            self.player.playImmediately(atRate: self.player.defaultRate)
            self.isPlaying = true
            self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
          }
        }
      }
    }
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
    max(bufferedUntil - currentTime, 0)
  }

  private func play(_ source: VideoSource, allowFallback: Bool) async {
    selectedSource = source
    errorMessage = nil
    didReachEnd = false
    isBuffering = true
    requiresVLC = false
    videoDisplaySize = nil
    videoCodec = "读取中"
    hdrFormat = "SDR"
    nominalFrameRate = 0
    chapters = []
    previewCache.removeAll(keepingCapacity: true)
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

    // Containers that AVPlayer commonly rejects should go straight to VLC when
    // the VLC runtime is actually bundled. MP4/MOV and other Apple-friendly
    // originals still stay on AVPlayer so HDR, Dolby Vision, AirPlay and PiP
    // keep using the system playback pipeline.
    if source.isOriginal, item.prefersVLCForOriginal, VLCAvailability.isAvailable {
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
    let asset = AVURLAsset(url: source.url, options: assetOptions)
    activeAsset = asset

    // Keep first-frame startup lean: AVPlayerItem(asset:) implicitly asks the
    // asset to load duration before the item becomes ready. Cineva already
    // loads duration/tracks asynchronously after playback starts, so avoid
    // duplicating that work on the critical startup path.
    let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [])
    playerItem.preferredForwardBufferDuration = fastStartEnabled ? 3 : 20

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

    let resumePosition = libraryStore.resumePosition(for: item)
    if resumePosition > 2, duration <= 0 || resumePosition < duration - 15 {
      currentTime = resumePosition
      player.seek(
        to: CMTime(seconds: resumePosition, preferredTimescale: 600),
        toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
        toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)
      ) { _ in }
    } else {
      currentTime = 0
    }
    player.playImmediately(atRate: player.defaultRate)
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate

    let generation = mediaInfoGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      // In fast-start mode, give AVPlayer a short head start before asking the
      // same remote asset for duration/tracks/chapters. Those inspections can
      // otherwise compete with the first media ranges on slower OpenList links.
      if self.fastStartEnabled {
        try? await Task.sleep(nanoseconds: 450_000_000)
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

  func previewImage(at seconds: Double) async -> UIImage? {
    guard let asset = activeAsset, seconds.isFinite, seconds >= 0 else { return nil }
    let bucket = Int(seconds / 10)
    if let cached = previewCache[bucket] { return cached }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 270)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
    guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
    let uiImage = UIImage(cgImage: result.image)
    previewCache[bucket] = uiImage
    if previewCache.count > 24 { previewCache.removeValue(forKey: previewCache.keys.min() ?? bucket) }
    return uiImage
  }

  func timelinePreview(at seconds: Double) async -> UIImage? {
    await previewImage(at: seconds)
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
    guard timeObserver == nil else { return }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 2),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let seconds = time.seconds.isFinite ? max(time.seconds, 0) : 0
        self.currentTime = seconds
        self.isPlaying = self.player.timeControlStatus == .playing
        self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate

        if let range = self.player.currentItem?.loadedTimeRanges.last?.timeRangeValue {
          let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
          self.bufferedUntil = end.isFinite ? max(end, 0) : 0
        }

        if let event = self.player.currentItem?.accessLog()?.events.last {
          let observed = event.observedBitrate
          let bytes = event.numberOfBytesTransferred
          self.transferredMegabytes = bytes > 0 ? Double(bytes) / 1_048_576 : 0

          if observed.isFinite, observed > 0 {
            self.networkMbps = observed / 1_000_000
          } else {
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastBandwidthSampleAt)
            if elapsed >= 0.45, bytes >= self.lastTransferredBytes {
              let delta = bytes - self.lastTransferredBytes
              self.networkMbps = elapsed > 0 ? Double(delta) * 8 / elapsed / 1_000_000 : 0
              self.lastTransferredBytes = bytes
              self.lastBandwidthSampleAt = now
            }
          }
        }

        let second = Int(seconds)
        if second >= 0, second != self.lastSavedSecond, second % 5 == 0 {
          self.lastSavedSecond = second
          self.saveProgress(force: false)
        }
      }
    }
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
        await self.handlePlaybackFailure(notification)
      }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentTime = self.duration
        self.isPlaying = false
        self.didReachEnd = true
        self.saveProgress(force: true)
      }
    }

    stallObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemPlaybackStalled,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.networkAutoRecoveryEnabled, !self.didReachEnd else { return }
        let now = Date()
        guard now.timeIntervalSince(self.lastStallRecoveryAt) > 6 else { return }
        self.lastStallRecoveryAt = now
        self.isBuffering = true
        let recoveryTime = max(self.player.currentTime().seconds, 0)
        self.player.seek(
          to: CMTime(seconds: recoveryTime, preferredTimescale: 600),
          toleranceBefore: CMTime(seconds: 0.35, preferredTimescale: 600),
          toleranceAfter: CMTime(seconds: 0.35, preferredTimescale: 600)
        ) { [weak self] finished in
          Task { @MainActor [weak self] in
            guard let self, finished else { return }
            self.player.playImmediately(atRate: self.player.defaultRate)
            self.isBuffering = false
          }
        }
      }
    }
  }

  private func handlePlaybackFailure(_ notification: Notification) async {
    guard !isFallingBack else { return }
    let reason = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
      .localizedDescription
    if selectedSource?.isOriginal == true, VLCAvailability.isAvailable {
      requiresVLC = true
      player.replaceCurrentItem(with: nil)
      isPlaying = false
      isBuffering = false
      errorMessage = nil
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
        if reason == .oldDeviceUnavailable {
          self.pause()
        }
      }
    }
  }

  private func saveProgress(force: Bool) {
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
