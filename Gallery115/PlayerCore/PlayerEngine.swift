import Foundation

/// Stable transport API shared by the existing backends. No AVFoundation,
/// MobileVLCKit, or FFmpeg types may cross this boundary.
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
protocol PlayerEngine: PlaybackEngineControlling {
  var playbackState: PlayerState { get }
  var statistics: PlayerStatistics { get }
  var loadingFeedback: PlayerLoadingFeedback? { get }
  var isInteractiveScrubLoading: Bool { get }
  @discardableResult func beginInteractiveScrub() -> Bool
  func interactiveScrub(to seconds: Double)
  func endInteractiveScrub(to seconds: Double, resumeAfter: Bool)
}

/// Optional capability. A backend without track switching does not manufacture
/// empty implementations of selection commands or expose another backend's tracks.
@MainActor
protocol PlayerTrackSelecting: AnyObject {
  var audioTracks: [PlayerTrack] { get }
  var subtitleTracks: [PlayerTrack] { get }
  var selectedAudioOptionID: String? { get }
  var selectedSubtitleOptionID: String? { get }
  func selectAudio(_ id: String?)
  func selectSubtitle(_ id: String?)
}

@MainActor
extension PlaybackEngineControlling {
  func enginePause() { pause() }
  func engineResume() { resume() }
  func engineTogglePlayback() { togglePlayback() }
  func engineSeek(to seconds: Double) { seek(to: seconds) }
  func engineSetPlaybackRate(_ rate: Float) { setPlaybackRate(rate) }
  func engineSetVolume(_ value: Float) { setVolume(value) }
}

@MainActor
extension PlayerEngine {
  var loadingFeedback: PlayerLoadingFeedback? {
    guard playbackState.needsLoadingIndicator || isInteractiveScrubLoading else { return nil }
    return PlayerLoadingFeedback(delayMilliseconds: 350, generation: 0)
  }
}
