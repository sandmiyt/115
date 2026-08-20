import AVFoundation
import AVKit
import CoreImage
import Observation
import QuartzCore
import SwiftUI
import UIKit

enum PlayerVideoLayout: String, CaseIterable {
  case fit
  case fill

  var gravity: AVLayerVideoGravity {
    switch self {
    case .fit: return .resizeAspect
    case .fill: return .resizeAspectFill
    }
  }

  var title: String {
    switch self {
    case .fit: return "适应屏幕"
    case .fill: return "铺满屏幕"
    }
  }
}

@MainActor
@Observable
final class SystemPlayerPresentationController: NSObject, AVPictureInPictureControllerDelegate {
  private(set) var isPictureInPictureActive = false
  private(set) var isPictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()
  private var pictureInPictureController: AVPictureInPictureController?
  private weak var attachedLayer: AVPlayerLayer?
  private let previewContext = CIContext(options: [.cacheIntermediates: false])

  func attach(playerLayer: AVPlayerLayer) {
    attachedLayer = playerLayer
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      isPictureInPictureSupported = false
      pictureInPictureController = nil
      return
    }

    if pictureInPictureController == nil {
      guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
        isPictureInPictureSupported = false
        return
      }
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      pictureInPictureController = controller
    }
    isPictureInPictureSupported = true
  }

  func detach(playerLayer: AVPlayerLayer) {
    guard attachedLayer === playerLayer else { return }
    attachedLayer = nil
    if pictureInPictureController?.isPictureInPictureActive == true {
      pictureInPictureController?.stopPictureInPicture()
    }
    pictureInPictureController = nil
    isPictureInPictureActive = false
  }

  func startPictureInPicture() {
    guard let controller = pictureInPictureController,
      AVPictureInPictureController.isPictureInPictureSupported()
    else { return }
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    } else if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    }
  }

  func stopPictureInPicture() {
    pictureInPictureController?.stopPictureInPicture()
  }

  /// Returns the exact frame currently presented by the primary AVPlayerLayer.
  /// This is intentionally sourced from the display layer rather than a separate
  /// AVAssetImageGenerator so timeline scrubbing never shows a thumbnail from a
  /// different timestamp or competes with the remote Range requests used by the
  /// real player.
  func displayedFrameImage(maximumDimension: CGFloat = 420) -> UIImage? {
    guard let pixelBuffer = attachedLayer?.displayedPixelBuffer() else { return nil }

    var image = CIImage(cvPixelBuffer: pixelBuffer)
    let extent = image.extent.integral
    guard extent.width > 0, extent.height > 0 else { return nil }

    let longestSide = max(extent.width, extent.height)
    if maximumDimension > 0, longestSide > maximumDimension {
      let scale = maximumDimension / longestSide
      image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    guard let cgImage = previewContext.createCGImage(image, from: image.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPictureInPictureActive = true
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPictureInPictureActive = false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    isPictureInPictureActive = false
  }
}

final class PlayerLayerView: UIView {
  override static var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

struct SystemPlayerView: UIViewRepresentable {
  let player: AVPlayer
  let presentationController: SystemPlayerPresentationController
  var videoLayout: PlayerVideoLayout = .fit

  func makeCoordinator() -> Coordinator {
    Coordinator(presentationController: presentationController)
  }

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .black
    view.playerLayer.player = player
    view.playerLayer.videoGravity = videoLayout.gravity
    context.coordinator.presentationController.attach(playerLayer: view.playerLayer)
    return view
  }

  func updateUIView(_ uiView: PlayerLayerView, context: Context) {
    if uiView.playerLayer.player !== player {
      uiView.playerLayer.player = player
    }
    if uiView.playerLayer.videoGravity != videoLayout.gravity {
      uiView.playerLayer.videoGravity = videoLayout.gravity
    }
    context.coordinator.presentationController.attach(playerLayer: uiView.playerLayer)
  }

  static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
    coordinator.presentationController.detach(playerLayer: uiView.playerLayer)
    uiView.playerLayer.player = nil
  }

  final class Coordinator {
    let presentationController: SystemPlayerPresentationController

    init(presentationController: SystemPlayerPresentationController) {
      self.presentationController = presentationController
    }
  }
}

/// Lightweight live scrub preview that mirrors the exact frame currently
/// visible in the primary AVPlayerLayer. Updates happen inside UIKit via a
/// display link so SwiftUI does not re-render the whole player at 30 fps.
struct SystemPlayerScrubPreviewView: UIViewRepresentable {
  let presentationController: SystemPlayerPresentationController

  func makeCoordinator() -> Coordinator {
    Coordinator(presentationController: presentationController)
  }

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView()
    view.backgroundColor = .black
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    context.coordinator.attach(view)
    return view
  }

  func updateUIView(_ uiView: UIImageView, context: Context) {
    context.coordinator.attach(uiView)
  }

  static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator: NSObject {
    private let presentationController: SystemPlayerPresentationController
    private weak var imageView: UIImageView?
    private var displayLink: CADisplayLink?
    private var lastCaptureTimestamp: CFTimeInterval = 0

    init(presentationController: SystemPlayerPresentationController) {
      self.presentationController = presentationController
    }

    func attach(_ imageView: UIImageView) {
      self.imageView = imageView
      if displayLink == nil {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
          link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        } else {
          link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
      captureFrame()
    }

    func stop() {
      displayLink?.invalidate()
      displayLink = nil
      imageView = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
      // The preferred frame rate already caps this at ~30 fps; the timestamp
      // check avoids duplicate work on ProMotion devices during mode changes.
      guard link.timestamp - lastCaptureTimestamp >= (1.0 / 34.0) else { return }
      lastCaptureTimestamp = link.timestamp
      captureFrame()
    }

    private func captureFrame() {
      guard let image = presentationController.displayedFrameImage(maximumDimension: 420) else { return }
      imageView?.image = image
    }
  }
}

struct AirPlayRoutePickerButton: UIViewRepresentable {
  var onPresentationChanged: (Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(onPresentationChanged: onPresentationChanged)
  }

  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.delegate = context.coordinator
    view.prioritizesVideoDevices = true
    view.tintColor = .white
    view.activeTintColor = UIColor(CinevaTheme.accent)
    view.backgroundColor = .clear
    return view
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    context.coordinator.onPresentationChanged = onPresentationChanged
    uiView.tintColor = .white
    uiView.activeTintColor = UIColor(CinevaTheme.accent)
  }

  final class Coordinator: NSObject, AVRoutePickerViewDelegate {
    var onPresentationChanged: (Bool) -> Void

    init(onPresentationChanged: @escaping (Bool) -> Void) {
      self.onPresentationChanged = onPresentationChanged
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
      onPresentationChanged(true)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
      onPresentationChanged(false)
    }
  }
}
