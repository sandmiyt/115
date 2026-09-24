import Observation
import SwiftUI

enum AlternatePlaybackBackend { case mpv, vlc }

@MainActor @Observable
final class AlternatePlaybackController: PlaybackEngineControlling {
  let mpv = MPVPlaybackController()
  let vlc = VLCPlaybackController()
  private(set) var backend: AlternatePlaybackBackend = .mpv
  var engineName: String { backend == .mpv ? "mpv" : "VLC" }
  private var engine: any PlaybackEngineControlling {
    if backend == .mpv { return mpv }
    return vlc
  }
  var currentTime: Double { engine.currentTime }
  var duration: Double { engine.duration }
  var bufferedUntil: Double { engine.bufferedUntil }
  var bufferedDuration: Double { engine.bufferedDuration }
  var bufferedRanges: [PlaybackBufferRange] { backend == .mpv ? mpv.bufferedRanges : [] }
  var isPlaying: Bool { engine.isPlaying }
  var isBuffering: Bool { engine.isBuffering }
  var didReachEnd: Bool { engine.didReachEnd }
  var networkMbps: Double { engine.networkMbps }
  var transferredMegabytes: Double { engine.transferredMegabytes }
  var volume: Float { engine.volume }
  var isInteractiveScrubLoading: Bool { backend == .mpv ? mpv.isInteractiveScrubLoading : vlc.isInteractiveScrubLoading }
  var errorMessage: String? { backend == .mpv ? mpv.errorMessage : vlc.errorMessage }
  var firstPlaybackSeconds: Double? { backend == .mpv ? mpv.firstPlaybackSeconds : vlc.firstPlaybackSeconds }
  var playbackStallCount: Int { backend == .mpv ? mpv.playbackStallCount : vlc.playbackStallCount }
  var playbackDiagnosticText: String { backend == .mpv ? mpv.playbackDiagnosticText : vlc.playbackDiagnosticText }

  func configure(backend: AlternatePlaybackBackend, source: VideoSource, item: CloudItem,
    libraryStore: LibraryStore, playbackRate: Float, fastStartEnabled: Bool, resumeAt: Double? = nil) {
    stop(saveProgress: false)
    self.backend = backend
    if backend == .mpv {
      mpv.configure(source: source, item: item, libraryStore: libraryStore,
        playbackRate: playbackRate, fastStartEnabled: fastStartEnabled, resumeAt: resumeAt)
    } else {
      vlc.configure(source: source, item: item, libraryStore: libraryStore,
        playbackRate: playbackRate, fastStartEnabled: fastStartEnabled, resumeAt: resumeAt)
    }
  }
  func pause() { engine.pause() }
  func resume() { engine.resume() }
  func togglePlayback() { engine.togglePlayback() }
  func seek(to seconds: Double) { engine.seek(to: seconds) }
  func seekBy(_ delta: Double) { seek(to: currentTime + delta) }
  func setPlaybackRate(_ rate: Float) { engine.setPlaybackRate(rate) }
  func setVolume(_ value: Float) { engine.setVolume(value) }
  func replay() { engine.replayFromStart() }
  func replayFromStart() { engine.replayFromStart() }
  func stop(saveProgress: Bool = true) {
    mpv.stop(saveProgress: saveProgress && backend == .mpv)
    vlc.stop(saveProgress: saveProgress && backend == .vlc)
  }
  func beginInteractiveScrub() -> Bool { backend == .mpv ? mpv.beginInteractiveScrub() : vlc.beginInteractiveScrub() }
  func interactiveScrub(to time: Double) {
    if backend == .mpv { mpv.interactiveScrub(to: time) } else { vlc.interactiveScrub(to: time) }
  }
  func endInteractiveScrub(to time: Double, resumeAfter: Bool) {
    if backend == .mpv { mpv.endInteractiveScrub(to: time, resumeAfter: resumeAfter) }
    else { vlc.endInteractiveScrub(to: time, resumeAfter: resumeAfter) }
  }
}

struct AlternatePlayerView: View {
  let controller: AlternatePlaybackController
  let fill: Bool
  var body: some View {
    if controller.backend == .mpv { MPVPlayerView(controller: controller.mpv, fill: fill) }
    else { VLCPlayerView(controller: controller.vlc) }
  }
}
