import SwiftUI
import UIKit

/// Explicit Phase 3 acceptance surface. Never selected as the normal backend.
struct FFmpegDecodeValidationView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  let source: VideoSource
  let startTime: Double
  @State private var session = FFmpegDecodeSession()
  @State private var slider = 0.0
  @State private var dragging = false

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        FFmpegValidationSurface(session: session)
          .frame(maxWidth: .infinity)
          .frame(height: 230)
          .background(.black)
          .clipped()
        Text("软件解码验证 · 暂不输出声音")
          .font(.headline)
        Text(session.mediaDescription).font(.caption).foregroundStyle(.secondary)
        if case .failed(let message) = session.state {
          Text(message).font(.callout).foregroundStyle(.red)
        } else {
          HStack {
            Text(session.state.title)
            if session.state.needsLoadingIndicator || session.state == .seeking { ProgressView() }
            Spacer()
            Text("\(Int(session.currentTime)) / \(Int(session.duration)) 秒").monospacedDigit()
          }.font(.caption)
          Slider(value: $slider, in: 0...max(1, session.duration), onEditingChanged: { editing in
            dragging = editing
            if !editing { session.seek(to: slider) }
          }).disabled(session.duration <= 0)
          HStack(spacing: 36) {
            Button { session.seek(to: session.currentTime - 10) } label: { Image(systemName: "gobackward.10") }
            Button { session.toggle() } label: { Image(systemName: session.wantsPlayback ? "pause.fill" : "play.fill") }
            Button { session.seek(to: session.currentTime + 10) } label: { Image(systemName: "goforward.10") }
          }.font(.title2)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("实际解码：视频 \(session.videoFrames) 帧 / 音频 \(session.audioFrames) 帧")
          Text("队列：\(session.packetBytes / 1024) KB 压缩数据 / \(session.frameCount) 待显示帧")
          if let latency = session.firstFrameSeconds { Text(String(format: "首帧入显示队列：%.2f 秒", latency)) }
          if let latency = session.lastSeekSeconds { Text(String(format: "最近定位至首帧入队：%.2f 秒", latency)) }
          Text("本阶段用 FFmpeg 解封装、软件解码，画面验证输出最高 720p。音频仅解码计数；硬解、音画同步、HDR、字幕及画中画尚未接入此入口。返回后可继续使用原播放器。")
            .foregroundStyle(.secondary)
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
      }
      .padding()
    }
    .navigationTitle("FFmpeg 解码验证")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { session.start(source: source, at: startTime) }
    .onDisappear { session.stop() }
    .onChange(of: session.currentTime) { _, time in if !dragging { slider = time } }
    .onChange(of: scenePhase) { _, phase in
      // No experimental decoder survives backgrounding/privacy lock.
      if phase != .active { session.stop(); dismiss() }
    }
  }
}

private struct FFmpegValidationSurface: UIViewRepresentable {
  let session: FFmpegDecodeSession
  func makeUIView(context: Context) -> Surface {
    let view = Surface()
    view.session = session
    view.layer.addSublayer(session.displayLayer)
    return view
  }
  func updateUIView(_ view: Surface, context: Context) { view.setNeedsLayout() }

  final class Surface: UIView {
    weak var session: FFmpegDecodeSession?
    override func layoutSubviews() {
      super.layoutSubviews()
      guard let session else { return }
      let radians = session.rotation * .pi / 180
      let quarterTurn = abs(sin(radians)) > 0.5
      let layer = session.displayLayer
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.setAffineTransform(.identity)
      layer.bounds = CGRect(origin: .zero, size: quarterTurn ?
        CGSize(width: bounds.height, height: bounds.width) : bounds.size)
      layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
      layer.setAffineTransform(CGAffineTransform(rotationAngle: radians))
      CATransaction.commit()
    }
  }
}
