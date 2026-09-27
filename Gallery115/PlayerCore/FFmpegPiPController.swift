import AVKit
import Observation

@MainActor @Observable
final class FFmpegPiPController: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
  private(set) var active = false
  private(set) var starting = false
  var requiresVideo: Bool { active || starting }
  private(set) var failure: String?
  @ObservationIgnored private weak var engine: FFmpegPlayerEngine?
  @ObservationIgnored private var controller: AVPictureInPictureController?
  var supported: Bool { controller != nil }
  init(engine: FFmpegPlayerEngine) {
    self.engine=engine
    super.init()
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    let source=AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:engine.renderer.layer,playbackDelegate:self)
    controller=AVPictureInPictureController(contentSource:source)
    controller?.delegate=self
    controller?.canStartPictureInPictureAutomaticallyFromInline=true
  }
  func toggle() {
    guard let controller else { return }
    if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
    else if controller.isPictureInPicturePossible { failure=nil; controller.startPictureInPicture() }
    else { failure="画中画尚未就绪；请等待首帧后重试。" }
  }
  func stop() { controller?.stopPictureInPicture() }
  func update() { controller?.invalidatePlaybackState() }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    if playing { engine?.resume() } else { engine?.pause() }
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start:.zero,duration:CMTime(seconds:max(0,engine?.duration ?? 0),preferredTimescale:60000))
  }
  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    engine?.isPlaying != true
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    // Native display layer handles scaling without converting HDR pixel buffers.
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    guard let engine else { completionHandler(); return }
    engine.seek(to:engine.currentTime+skipInterval.seconds)
    Task { @MainActor [weak engine] in
      // Complete after the new generation leaves seeking, not before a frame
      // for that target exists. The bounded error path also releases PiP's UI.
      for _ in 0..<100 {
        guard let engine, engine.playbackState == .seeking else { break }
        try? await Task.sleep(for:.milliseconds(100))
      }
      completionHandler()
    }
  }
  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { starting=true }
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { starting=false; active=true }
  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { starting=false; active=false }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    starting=false; active=false; failure=error.localizedDescription
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    completionHandler(engine?.renderer.layer.superlayer != nil)
  }
}
