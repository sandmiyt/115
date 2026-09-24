import Foundation
import Observation
import SwiftUI

#if canImport(MobileVLCKit)
  import MobileVLCKit
  import UIKit

  @MainActor
  @Observable
  final class VLCPlaybackController: PlaybackEngineControlling {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isInteractiveScrubLoading = false
    private(set) var didReachEnd = false
    private(set) var networkMbps: Double = 0
    private(set) var transferredMegabytes: Double = 0
    private(set) var volume: Float = 1
    var bufferedUntil: Double { currentTime }
    var bufferedDuration: Double { 0 }

    let player = VLCMediaPlayer()
    private var pollTimer: Timer?
    private var item: CloudItem?
    private var libraryStore: LibraryStore?
    private var lastSavedSecond = -1
    private var lastState: VLCMediaPlayerState = .stopped
    private var maxObservedTime: Double = 0
    private var playbackGeneration = UUID()
    private var lastInteractiveSeekAt: TimeInterval = 0
    private var pendingInteractiveSeek: Double?
    private var interactiveScrubActive = false
    private var lastAppliedScrubTarget: Double?
    @ObservationIgnored private var interactiveSeekTask: Task<Void, Never>?

    func configure(
      source: VideoSource,
      item: CloudItem,
      libraryStore: LibraryStore,
      playbackRate: Float,
      fastStartEnabled: Bool
    ) {
      stop(saveProgress: false)
      let generation = UUID()
      playbackGeneration = generation
      self.item = item
      self.libraryStore = libraryStore
      didReachEnd = false
      currentTime = 0
      duration = max(item.duration, libraryStore.knownDuration(for: item))
      networkMbps = 0
      transferredMegabytes = 0
      maxObservedTime = 0
      lastSavedSecond = -1

      let media = VLCMedia(url: source.url)
      // Originals often arrive in bursts. 650 ms exhausts almost immediately
      // between responses; keep a bounded runway without changing the source.
      let cacheMilliseconds = item.isDiscImage ? 4200 : (fastStartEnabled ? 1800 : 3500)
      var options: [String: Any] = [
        "http-user-agent": APIClient.userAgent,
        "network-caching": cacheMilliseconds,
        "disc-caching": cacheMilliseconds,
        "file-caching": cacheMilliseconds,
      ]
      if let authorization = source.headers["Authorization"],
        authorization.hasPrefix("Basic "),
        let data = Data(base64Encoded: String(authorization.dropFirst(6))),
        let pair = String(data: data, encoding: .utf8),
        let separator = pair.firstIndex(of: ":")
      {
        options["http-user"] = String(pair[..<separator])
        options["http-pwd"] = String(pair[pair.index(after: separator)...])
      }
      media.addOptions(options)
      player.media = media
      player.rate = min(max(playbackRate, 0.5), 2.0)
      player.play()
      isPlaying = true
      isBuffering = true

      let resume = libraryStore.resumePosition(for: item)
      if resume > 2, duration <= 0 || resume < duration - 15 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          guard let self,
            self.playbackGeneration == generation,
            self.item?.id == item.id
          else { return }
          self.seek(to: resume)
        }
      }
      startPolling()
    }

    func attachDrawable(_ view: UIView) {
      player.drawable = view
    }

    func detachDrawable(_ view: UIView) {
      if let drawable = player.drawable as? UIView, drawable === view {
        player.drawable = nil
      }
    }

    func pause() {
      cancelInteractiveScrub()
      player.pause()
      isPlaying = false
      isBuffering = false
      saveProgress(force: true)
    }

    func resume() {
      didReachEnd = false
      player.play()
      isPlaying = true
    }

    func togglePlayback() {
      isPlaying ? pause() : resume()
    }

    func seek(to seconds: Double) {
      cancelInteractiveScrub()
      let target = clampedSeekTarget(seconds)
      currentTime = target
      applySeek(target)
    }

    @discardableResult
    func beginInteractiveScrub() -> Bool {
      let shouldResume = isPlaying || player.state == .playing || player.state == .buffering
      cancelInteractiveScrub()
      interactiveScrubActive = true
      player.pause()
      isPlaying = false
      isBuffering = false
      lastInteractiveSeekAt = 0
      lastAppliedScrubTarget = nil
      return shouldResume
    }

    /// VLC has no seek-completion callback. Use a trailing, latest-target task
    /// capped at 8 fps so a touch burst cannot continually restart the decoder.
    func interactiveScrub(to seconds: Double) {
      guard interactiveScrubActive else { return }
      let target = clampedSeekTarget(seconds)
      currentTime = target
      pendingInteractiveSeek = target
      guard interactiveSeekTask == nil else { return }
      let generation = playbackGeneration
      let delay = max(0.125 - (ProcessInfo.processInfo.systemUptime - lastInteractiveSeekAt), 0)
      interactiveSeekTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard let self, self.playbackGeneration == generation, self.interactiveScrubActive else { return }
        self.interactiveSeekTask = nil
        guard let latest = self.pendingInteractiveSeek else { return }
        self.pendingInteractiveSeek = nil
        guard self.lastAppliedScrubTarget != latest else { return }
        self.lastInteractiveSeekAt = ProcessInfo.processInfo.systemUptime
        self.lastAppliedScrubTarget = latest
        self.applySeek(latest)
      }
    }

    func endInteractiveScrub(to seconds: Double, resumeAfter: Bool) {
      let target = clampedSeekTarget(seconds)
      let alreadyRequested = lastAppliedScrubTarget == target
      cancelInteractiveScrub()
      currentTime = target
      if !alreadyRequested { applySeek(target) }
      // Do not manufacture a 180 ms loading flash on every release. The screen
      // debounces actual buffering; a cached seek needs no loading overlay.
      if resumeAfter {
        player.play()
        isPlaying = true
      }
    }

    private func cancelInteractiveScrub() {
      interactiveSeekTask?.cancel()
      interactiveSeekTask = nil
      pendingInteractiveSeek = nil
      interactiveScrubActive = false
      isInteractiveScrubLoading = false
    }

    private func clampedSeekTarget(_ seconds: Double) -> Double {
      let upper = duration > 0 ? duration : max(seconds, currentTime + 60)
      return min(max(seconds, 0), upper)
    }

    private func applySeek(_ target: Double) {
      player.time = VLCTime(int: Int32(min(target * 1000, Double(Int32.max))))
    }

    func seekBy(_ delta: Double) {
      seek(to: currentTime + delta)
    }

    func setPlaybackRate(_ value: Float) {
      player.rate = min(max(value, 0.5), 2.0)
    }

    func setVolume(_ value: Float) {
      let clamped = min(max(value, 0), 1)
      volume = clamped
      if let audio = player.audio {
        audio.volume = Int32((clamped * 100).rounded())
      }
    }

    func replay() {
      didReachEnd = false
      seek(to: 0)
      resume()
    }

    func replayFromStart() { replay() }

    func stop(saveProgress: Bool = true) {
      cancelInteractiveScrub()
      if saveProgress { self.saveProgress(force: true) }
      // Invalidate delayed work (for example resume seeking) from the previous
      // media item before the controller is reused for another episode.
      playbackGeneration = UUID()
      pollTimer?.invalidate()
      pollTimer = nil
      player.stop()
      player.drawable = nil
      isPlaying = false
      isBuffering = false
      lastState = .stopped
    }

    private func startPolling() {
      pollTimer?.invalidate()
      pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.poll()
        }
      }
      pollTimer?.tolerance = 0.08
    }

    private func poll() {
      let state = player.state
      let milliseconds = max(player.time.intValue, 0)
      if !interactiveScrubActive {
        currentTime = Double(milliseconds) / 1000
        maxObservedTime = max(maxObservedTime, currentTime)
      }

      if let mediaLength = player.media?.length.intValue, mediaLength > 0 {
        duration = Double(mediaLength) / 1000
      }

      isPlaying = !interactiveScrubActive && state == .playing
      isBuffering = !interactiveScrubActive && state == .opening
      if let audio = player.audio {
        volume = Float(audio.volume) / 100
      }

      if let media = player.media {
        let stats = media.statistics
        let bitrate = Double(stats.inputBitrate)
        networkMbps = bitrate > 0 ? bitrate * 8 / 1_000_000 : 0
        transferredMegabytes = Double(stats.readBytes) / 1_048_576
      }

      if state == .stopped, lastState == .playing, duration > 0, maxObservedTime >= duration * 0.92 {
        didReachEnd = true
        saveProgress(force: true)
      }
      lastState = state
      saveProgress(force: false)
    }

    private func saveProgress(force: Bool) {
      guard !interactiveScrubActive, let item, let libraryStore else { return }
      let second = max(0, Int(currentTime.rounded(.down)))
      if force || second >= lastSavedSecond + 5 {
        lastSavedSecond = second
        libraryStore.recordPlayback(item, position: currentTime, duration: duration)
      }
    }
  }

  struct VLCPlayerView: UIViewRepresentable {
    let controller: VLCPlaybackController

    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.backgroundColor = .black
      controller.attachDrawable(view)
      return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
      controller.attachDrawable(uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Void) {}
  }

  enum VLCAvailability {
    static let isAvailable = true
  }
#else
  @MainActor
  @Observable
  final class VLCPlaybackController: PlaybackEngineControlling {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isInteractiveScrubLoading = false
    private(set) var didReachEnd = false
    private(set) var networkMbps: Double = 0
    private(set) var transferredMegabytes: Double = 0
    private(set) var volume: Float = 1
    var bufferedUntil: Double { currentTime }
    var bufferedDuration: Double { 0 }

    func configure(
      source: VideoSource,
      item: CloudItem,
      libraryStore: LibraryStore,
      playbackRate: Float,
      fastStartEnabled: Bool
    ) {}
    func pause() {}
    func resume() {}
    func togglePlayback() {}
    func seek(to seconds: Double) {}
    func beginInteractiveScrub() -> Bool { false }
    func interactiveScrub(to seconds: Double) {}
    func endInteractiveScrub(to seconds: Double, resumeAfter: Bool) {}
    func seekBy(_ delta: Double) {}
    func setPlaybackRate(_ value: Float) {}
    func setVolume(_ value: Float) {}
    func replay() {}
    func replayFromStart() {}
    func stop(saveProgress: Bool = true) {}
  }

  struct VLCPlayerView: View {
    let controller: VLCPlaybackController

    var body: some View {
      ContentUnavailableView(
        "VLC 内核未安装",
        systemImage: "play.slash",
        description: Text("运行 pod install 后即可启用 MobileVLCKit 原画兜底。")
      )
    }
  }

  enum VLCAvailability {
    static let isAvailable = false
  }
#endif
