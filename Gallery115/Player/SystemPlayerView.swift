import AVFoundation
import AVKit
import SwiftUI

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

struct SystemPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  var videoLayout: PlayerVideoLayout = .fit
  var showsPlaybackControls = false

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.videoGravity = videoLayout.gravity
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.showsPlaybackControls = showsPlaybackControls
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    if controller.videoGravity != videoLayout.gravity {
      controller.videoGravity = videoLayout.gravity
    }
    if controller.showsPlaybackControls != showsPlaybackControls {
      controller.showsPlaybackControls = showsPlaybackControls
    }
  }
}
