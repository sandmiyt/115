import SwiftUI

#if canImport(MobileVLCKit)
  import MobileVLCKit
  import UIKit

  struct VLCPlayerView: UIViewRepresentable {
    let source: VideoSource

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.backgroundColor = .black
      let mediaPlayer = VLCMediaPlayer()
      mediaPlayer.drawable = view
      let media = VLCMedia(url: source.url)
      media.addOptions(["http-user-agent": APIClient.userAgent, "network-caching": 1500])
      mediaPlayer.media = media
      context.coordinator.player = mediaPlayer
      mediaPlayer.play()
      return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
      coordinator.player?.stop()
      coordinator.player = nil
    }

    final class Coordinator {
      var player: VLCMediaPlayer?
    }
  }

  enum VLCAvailability {
    static let isAvailable = true
  }
#else
  struct VLCPlayerView: View {
    let source: VideoSource

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
