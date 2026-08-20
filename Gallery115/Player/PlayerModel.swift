import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import UIKit

struct PlayerMediaOption: Identifiable {
  let id: String
  let title: String
  fileprivate let option: AVMediaSelectionOption
}

@MainActor
@Observable
final class PlayerModel {
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

  var errorMessage: String?
  var didFallbackFromOriginal = false

  let player = AVPlayer()

  private let item: CloudItem
  private let api: APIClient
  private let libraryStore: LibraryStore
  private let defaultQuality: AppState.DefaultQuality
  private var audioGroup: AVMediaSelectionGroup?
  private var subtitleGroup: AVMediaSelectionGroup?
  nonisolated(unsafe) private var timeObserver: Any?
  nonisolated(unsafe) private var failureObserver: NSObjectProtocol?
  nonisolated(unsafe) private var endObserver: NSObjectProtocol?
  nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
  nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
  private var lastSavedSecond = -1
  private var lastRemoteHistorySecond = -60
  private var isFallingBack = false
  private var lastTransferredBytes: Int64 = 0
  private var lastBandwidthSampleAt = Date()

  init(
    item: CloudItem, api: APIClient, libraryStore: LibraryStore,
    defaultQuality: AppState.DefaultQuality
  ) {
    self.item = item
    self.api = api
    self.libraryStore = libraryStore
    self.defaultQuality = defaultQuality
    self.duration = max(item.duration, libraryStore.knownDuration(for: item))
    player.automaticallyWaitsToMinimizeStalling = true
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

  func replay() async {
    didReachEnd = false
    currentTime = 0
    bufferedUntil = max(bufferedUntil, 0)
    await player.seek(to: .zero)
    player.play()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
  }

  func togglePlayback() {
    if player.timeControlStatus == .playing {
      pause()
    } else {
      resume()
    }
  }

  func seek(to seconds: Double) {
    let upper = duration > 0 ? duration : max(seconds, currentTime + 60)
    let target = min(max(seconds, 0), upper)
    currentTime = target
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
  }

  func seekBy(_ delta: Double) {
    seek(to: currentTime + delta)
  }

  func setPlaybackRate(_ rate: Float) {
    let safeRate = min(max(rate, 0.5), 2.0)
    player.defaultRate = safeRate
    if player.timeControlStatus == .playing {
      player.rate = safeRate
    }
  }

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

    let asset: AVURLAsset
    if source.headers.isEmpty {
      asset = AVURLAsset(url: source.url)
    } else {
      asset = AVURLAsset(
        url: source.url,
        options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
      )
    }

    do {
      let playable = try await asset.load(.isPlayable)
      if !playable {
        throw NSError(
          domain: "Gallery115.Player", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "当前原画编码或容器无法由系统播放器直接打开。"])
      }
      let loadedDuration = try? await asset.load(.duration)
      if let loadedDuration, loadedDuration.seconds.isFinite, loadedDuration.seconds > 0 {
        duration = loadedDuration.seconds
      }
      let characteristics = await detectVideoCharacteristics(asset)
      videoDisplaySize = characteristics.size
      videoCodec = characteristics.codec
      hdrFormat = characteristics.hdr
      nominalFrameRate = characteristics.frameRate
    } catch {
      // Direct-play-first: preserve Apple's native HDR/Dolby Vision pipeline whenever
      // AVPlayer can open the original. VLC is only used after the system player has
      // actually rejected the original container/codec.
      if source.isOriginal, VLCAvailability.isAvailable {
        player.replaceCurrentItem(with: nil)
        requiresVLC = true
        isPlaying = false
        isBuffering = false
        videoCodec = item.fileExtension.uppercased()
        hdrFormat = "由 VLC 解码"
        errorMessage = nil
        return
      }
      if source.isOriginal, allowFallback, let fallback = bestTranscode {
        didFallbackFromOriginal = true
        await play(fallback, allowFallback: false)
        return
      }
      errorMessage = error.localizedDescription
      isBuffering = false
      return
    }

    let playerItem = AVPlayerItem(asset: asset)
    // Give remote WebDAV playback a modest forward buffer without capping bitrate.
    // Original quality remains untouched; AVPlayer still chooses the native decode path.
    playerItem.preferredForwardBufferDuration = 20
    installItemObservers(for: playerItem)
    player.replaceCurrentItem(with: playerItem)

    await loadMediaSelectionOptions(asset: asset, playerItem: playerItem)

    let resumePosition = libraryStore.resumePosition(for: item)
    if resumePosition > 2, duration <= 0 || resumePosition < duration - 15 {
      currentTime = resumePosition
      await player.seek(to: CMTime(seconds: resumePosition, preferredTimescale: 600))
    } else {
      currentTime = 0
    }
    player.play()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
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
