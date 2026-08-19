import AVFoundation
import CoreGraphics
import Foundation
import Observation

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
  private var lastSavedSecond = -1
  private var isFallingBack = false

  init(
    item: CloudItem, api: APIClient, libraryStore: LibraryStore,
    defaultQuality: AppState.DefaultQuality
  ) {
    self.item = item
    self.api = api
    self.libraryStore = libraryStore
    self.defaultQuality = defaultQuality
    self.duration = max(item.duration, 0)
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
  }

  func prepareAndPlay() async {
    guard !isPreparing else { return }
    isPreparing = true
    didReachEnd = false
    defer { isPreparing = false }

    do {
      sources = try await api.videoSources(for: item)
      guard !sources.isEmpty else {
        errorMessage = "115 没有返回可播放清晰度。"
        return
      }

      let preferred: VideoSource?
      switch defaultQuality {
      case .highestTranscode:
        preferred = bestTranscode ?? sources.first
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
    player.play()
    isPlaying = true
    isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
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
    let safeRate = min(max(rate, 0.25), 3.0)
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

  private func play(_ source: VideoSource, allowFallback: Bool) async {
    selectedSource = source
    errorMessage = nil
    didReachEnd = false
    isBuffering = true
    videoDisplaySize = nil
    audioOptions = []
    subtitleOptions = []
    audioGroup = nil
    subtitleGroup = nil
    selectedAudioOptionID = nil
    selectedSubtitleOptionID = nil

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
          userInfo: [NSLocalizedDescriptionKey: "当前原画编码或地址无法由系统播放器打开。"])
      }
      let loadedDuration = try? await asset.load(.duration)
      if let loadedDuration, loadedDuration.seconds.isFinite, loadedDuration.seconds > 0 {
        duration = loadedDuration.seconds
      }
      videoDisplaySize = await detectVideoDisplaySize(asset)
    } catch {
      if source.isOriginal, allowFallback, let fallback = bestTranscode {
        didFallbackFromOriginal = true
        await play(fallback, allowFallback: false)
        return
      }
      errorMessage = error.localizedDescription
      return
    }

    let playerItem = AVPlayerItem(asset: asset)
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
  }

  private func detectVideoDisplaySize(_ asset: AVAsset) async -> CGSize? {
    guard let tracks = try? await asset.loadTracks(withMediaType: .video),
      let track = tracks.first,
      let naturalSize = try? await track.load(.naturalSize),
      let preferredTransform = try? await track.load(.preferredTransform)
    else {
      return nil
    }

    let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
    let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
    guard size.width > 0, size.height > 0 else { return nil }
    return size
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
    if selectedSource?.isOriginal == true, let fallback = bestTranscode {
      isFallingBack = true
      didFallbackFromOriginal = true
      await play(fallback, allowFallback: false)
      isFallingBack = false
    } else {
      errorMessage = reason ?? "视频播放失败。"
    }
  }

  private func saveProgress(force: Bool) {
    let seconds = player.currentTime().seconds
    guard seconds.isFinite, seconds >= 0 else { return }
    libraryStore.recordPlayback(item, position: seconds)
    if force || Int(seconds) % 15 == 0 {
      Task {
        await api.updateVideoHistory(
          pickCode: item.pickCode,
          seconds: Int(seconds),
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
