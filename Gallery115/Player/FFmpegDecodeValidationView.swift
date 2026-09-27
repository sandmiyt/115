import SwiftUI
import UIKit

/// Explicit Phase 5 acceptance surface. Never selected as the normal backend.
struct FFmpegDecodeValidationView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let source: VideoSource
  let startTime: Double
  @State private var session = FFmpegDecodeSession()
  @State private var player = FFmpegPlayerEngine()
  @State private var activeMode: FFmpegReadMode = .videoOnlySequential
  @State private var slider = 0.0
  @State private var dragging = false
  @State private var preferHardware = true
  @State private var copiedDiagnostics = false
  @State private var readMode: FFmpegReadMode = .videoOnlySequential
  @State private var comparisonPosition = 0.0
  @State private var trials: [FFmpegDiagnosticTrial] = []
  @State private var started = false

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        Group {
          if activeMode.outputsAudio { FFmpegPlayerSurface(engine:player,layout:.fit) }
          else { FFmpegValidationSurface(session:session) }
        }
          .frame(maxWidth: .infinity)
          .frame(height: 230)
          .background(.black)
          .clipped()
        Text(activeMode.outputsAudio ? "完整音视频输出对照" : "原生渲染验证 · 无声对照")
          .font(.headline)
        VStack(alignment: .leading, spacing: 8) {
          Text("远程 MP4 读取模式").font(.subheadline.weight(.medium))
          Picker("远程 MP4 读取模式", selection: $readMode) {
            ForEach(FFmpegReadMode.allCases) { mode in Text(mode.title).tag(mode) }
          }.pickerStyle(.menu)
          Text(activeMode.outputsAudio ? activeMode.title : session.modeDescription).font(.caption)
          Text(String(format: "A/B 共用当前取流 URL · 固定起点 %.3f 秒", comparisonPosition)).font(.caption)
          HStack {
            Button("重测当前模式") { restart() }
            Button("设为当前进度并重测") { restart(at: activeTime) }
          }.font(.caption)
          Text("切换 A/B 会从同一起点重新验证。起播后计时 10 秒（含缓冲等待），结果保留在下方；暂停或手动拖动会标记未完成的对照。")
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Text(activeMode.outputsAudio ? (player.statistics.codec ?? "正在探测媒体") : session.mediaDescription).font(.caption).foregroundStyle(.secondary)
        Text(activeMode.outputsAudio ? (player.statistics.decoder ?? "等待解码") : session.decoderDescription).font(.subheadline.weight(.medium))
        Toggle("优先硬件解码", isOn: $preferHardware)
          .font(.subheadline)
        if case .failed(let message) = activeState {
          Text(message).font(.callout).foregroundStyle(.red)
          Button("从头验证") {
            restart(at: 0)
          }
        } else {
          HStack {
            Text(activeState.title)
            if activeState.needsLoadingIndicator || activeState == .seeking { ProgressView() }
            Spacer()
            Text("\(Int(activeTime)) / \(Int(activeDuration)) 秒").monospacedDigit()
          }.font(.caption)
          Slider(value: $slider, in: 0...max(1, activeDuration), onEditingChanged: { editing in
            dragging = editing
            if !editing { seek(to: slider) }
          }).disabled(activeDuration <= 0)
          HStack(spacing: 36) {
            Button { seek(to: activeTime - 10) } label: { Image(systemName: "gobackward.10") }
            Button { toggle() } label: { Image(systemName: activeWants ? "pause.fill" : "play.fill") }
            Button { seek(to: activeTime + 10) } label: { Image(systemName: "goforward.10") }
          }.font(.title2)
        }
        VStack(alignment: .leading, spacing: 6) {
          if activeMode.outputsAudio { Text(player.diagnostics).textSelection(.enabled) }
          else {
          Text(session.outputDescription)
          Text(session.colorDescription)
          Text("渲染器：Apple Native · NV12 / P010")
          Text(session.pipelineDescription)
          Text(session.containerDescription)
          Text(session.nativeStageDescription)
          Text(session.recoveryDescription)
          Text(session.ioDescription)
          Text(session.ioTimingDescription)
          Text(session.ioJumpDescription)
          Text(session.readStatistics)
          Text(session.bufferDescription)
          Text(String(format: "压缩视频队列：%.2f 秒（尚未解码）", session.compressedVideoSeconds))
          Text("解码器输出 \(session.decodedVideoFrames) 帧 · 目标前预滚 \(session.prerollFrames) 帧")
          if let warning = session.audioWarning { Text(warning).foregroundStyle(.secondary) }
          Text(session.timingDescription)
          Text("显示入队 \(session.submittedFrames) 帧 / 丢弃迟到帧 \(session.droppedFrames) / 显示恢复 \(session.renderRecoveries) 次")
          Text("首帧可显示：\(session.displayReadiness) · \(session.renderingDescription)")
          Text("设备 HDR 播放资格：\(session.hdrDisplayEligible ? "支持" : "未提供")（不等于当前屏幕实测亮度）")
          Text("实际输出：硬解 \(session.hardwareFrames) 帧 / 软解 \(session.softwareFrames) 帧")
          if let reason = session.fallbackDescription { Text(reason).foregroundStyle(.secondary) }
          Text("目标位置后输出：视频 \(session.videoFrames) 帧 / 音频解码 \(session.audioFrames) 帧")
          Text("队列：\(session.packetBytes / 1024) KB 压缩数据 / \(session.frameCount) 待显示帧")
          if let latency = session.firstFrameSeconds { Text(String(format: "首帧入显示队列：%.2f 秒", latency)) }
          if let latency = session.lastSeekSeconds { Text(String(format: "最近定位至首帧入队：%.2f 秒", latency)) }
          Text("硬解保持原分辨率和像素缓冲，HDR10 / HLG 保留 10 位及色彩标记；软件对照最高 720p，保留 HDR 位深。A 模式音频仅解码计数，B 模式不解码音频。Dolby Vision、字幕、音画同步及画中画尚未接入此入口。")
            .foregroundStyle(.secondary)
          }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 12) {
          Text("A/B 诊断记录").font(.headline)
          Text("首帧指提交显示层；AVIO、包跳转和读取耗时自会话创建累计至观察点，并非实际 HTTP 请求统计。压缩队列是观察点快照。")
            .foregroundStyle(.secondary)
          ForEach(trials) { trial in
            Text(trial.text).textSelection(.enabled)
            Divider()
          }
          Text("当前记录\n" + activeTrial.text).textSelection(.enabled)
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        Button(copiedDiagnostics ? "播放诊断已复制" : "复制播放诊断") {
          UIPasteboard.general.string = activeDiagnostics + "\n\nA/B 诊断记录\n"
            + (trials + [activeTrial]).map(\.text).joined(separator: "\n\n")
          copiedDiagnostics = true
        }.font(.caption)
        Spacer(minLength: 0)
      }
      .padding()
    }
    .navigationTitle("FFmpeg 解码验证")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      guard !started else { return }
      started = true
      comparisonPosition = startTime.isFinite ? max(0, startTime) : 0
      session.start(source: source, at: comparisonPosition, preferHardware: preferHardware, mode: readMode)
    }
    .onChange(of: preferHardware) { _, _ in restart() }
    .onChange(of: readMode) { _, _ in restart() }
    .onDisappear { session.stop(); player.stop() }
    .onChange(of: activeTime) { _, time in if !dragging { slider = time } }
    .onChange(of: scenePhase) { _, phase in
      // No experimental decoder survives backgrounding/privacy lock.
      if phase != .active { session.stop(); player.stop(); dismiss() }
    }
  }

  private var activeTime: Double { activeMode.outputsAudio ? player.currentTime : session.currentTime }
  private var activeDuration: Double { activeMode.outputsAudio ? player.duration : session.duration }
  private var activeState: PlayerState { activeMode.outputsAudio ? player.playbackState : session.state }
  private var activeWants: Bool { activeMode.outputsAudio ? player.wantsPlayback : session.wantsPlayback }
  private var activeTrial: FFmpegDiagnosticTrial { activeMode.outputsAudio ? player.trial : session.trial }
  private var activeDiagnostics: String { activeMode.outputsAudio ? player.diagnostics : session.diagnosticText }
  private func seek(to time: Double) { if activeMode.outputsAudio { player.seek(to:time) } else { session.seek(to:time) } }
  private func toggle() { if activeMode.outputsAudio { player.togglePlayback() } else { session.toggle() } }
  private func restart(at position: Double? = nil) {
    session.stop(); player.stop()
    trials.append(activeTrial)
    if let position { comparisonPosition = position.isFinite ? max(0, position) : 0 }
    copiedDiagnostics = false; slider = comparisonPosition; activeMode=readMode
    if readMode.outputsAudio {
      player.start(source:source,item:item,api:appState.api,library:appState.libraryStore,
        at:comparisonPosition,useCache:readMode == .cachedAudio,preferHardware:preferHardware,recordsHistory:false, inputBackend:readMode == .standard ? .ffmpegHTTP : readMode == .directAudio ? .customAVIODirect : .customAVIOCached)
    } else {
      session.start(source:source,at:comparisonPosition,preferHardware:preferHardware,mode:readMode)
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
