import AVFoundation
import AVKit
import Observation
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

  func attach(playerLayer: AVPlayerLayer) {
    attachedLayer = playerLayer
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      isPictureInPictureSupported = false
      pictureInPictureController = nil
      return
    }

    if pictureInPictureController == nil {
      let controller = AVPictureInPictureController(playerLayer: playerLayer)
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
