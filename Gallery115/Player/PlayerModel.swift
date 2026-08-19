import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
  private(set) var sources: [VideoSource] = []
  private(set) var selectedSource: VideoSource?
  private(set) var isPreparing = false
  var errorMessage: String?
  var didFallbackFromOriginal = false

  let player = AVPlayer()

  private let item: CloudItem
  private let api: APIClient
  private let libraryStore: LibraryStore
  private let defaultQuality: AppState.DefaultQuality
  nonisolated(unsafe) private var timeObserver: Any?
  nonisolated(unsafe) private var failureObserver: NSObjectProtocol?
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
  }

  deinit {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    if let failureObserver {
      NotificationCenter.default.removeObserver(failureObserver)
    }
  }

  func prepareAndPlay() async {
    guard !isPreparing else { return }
    isPreparing = true
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
      installObserversIfNeeded()
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
    saveProgress(force: true)
  }

  func resume() {
    player.play()
  }

  var bestTranscode: VideoSource? {
    sources.filter { !$0.isOriginal }.max { $0.definition < $1.definition }
  }

  var original: VideoSource? {
    sources.first(where: \.isOriginal)
  }

  private func play(_ source: VideoSource, allowFallback: Bool) async {
    selectedSource = source
    errorMessage = nil

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
    player.replaceCurrentItem(with: playerItem)

    let resume = libraryStore.resumePosition(for: item)
    if resume > 2, item.duration <= 0 || resume < item.duration - 15 {
      await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
    }
    player.play()
  }

  private func installObserversIfNeeded() {
    guard timeObserver == nil else { return }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1, preferredTimescale: 2),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let second = Int(time.seconds.isFinite ? time.seconds : 0)
        if second >= 0, second != self.lastSavedSecond, second % 5 == 0 {
          self.lastSavedSecond = second
          self.saveProgress(force: false)
        }
      }
    }

    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      Task { @MainActor in
        await self.handlePlaybackFailure(notification)
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
          watchEnd: item.duration > 0 && seconds >= item.duration - 10
        )
      }
    }
  }
}
