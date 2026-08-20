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

      var options: [String: Any] = [
        "http-user-agent": APIClient.userAgent,
        "network-caching": 1800,
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
