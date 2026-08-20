import AVFoundation
import SwiftUI
import UIKit

struct PlayerScreen: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState

  @State private var currentItem: CloudItem
  @State private var playlist: [CloudItem] = []
  @State private var loadedPlaylistParentID: String?
  @State private var model: PlayerModel?
  @State private var useVLC = false
  @State private var showInfo = false
  @State private var videoLayout: PlayerVideoLayout = .fit
  @State private var playbackRate: Float = 1.0
  @State private var isLocked = false
  @State private var controlsVisible = true
  @State private var gestureHUD: String?
  @State private var hudTask: Task<Void, Never>?
  @State private var controlsTask: Task<Void, Never>?
  @State private var scrubValue: Double = 0
  @State private var isScrubbing = false
  @State private var isGestureInteracting = false
  @State private var gestureStartBrightness: CGFloat?
  @State private var gestureStartVolume: Float?

  init(item: CloudItem) {
    _currentItem = State(initialValue: item)
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black.ignoresSafeArea()

        playerLayer
          .frame(width: proxy.size.width, height: proxy.size.height)
          .background(Color.black)
          .ignoresSafeArea()

        interactionLayer(proxy: proxy)

        if isLocked {
          lockShield(proxy: proxy)
        } else if controlsVisible {
          VStack(spacing: 0) {
            topOverlay(proxy: proxy)
            Spacer(minLength: 0)
            bottomOverlay(proxy: proxy)
          }
          .transition(.opacity)
        }

        if model?.isBuffering == true {
          ProgressView()
            .controlSize(.large)
            .tint(.white)
            .padding(16)
            .background(.black.opacity(0.38), in: Circle())
            .allowsHitTesting(false)
        }

        if let gestureHUD {
          Text(gestureHUD)
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(.black.opacity(0.76), in: Capsule())
            .transition(.scale.combined(with: .opacity))
            .allowsHitTesting(false)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(Color.black)
    .ignoresSafeArea()
    .statusBarHidden(true)
    .sheet(isPresented: $showInfo) {
      PlayerInfoSheet(
        item: currentItem,
        model: model,
        videoLayout: videoLayout,
        playbackRate: playbackRate,
        playlistCount: playlist.count
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .alert(
      "播放失败",
      isPresented: Binding(
        get: { model?.errorMessage != nil },
        set: { if !$0 { model?.errorMessage = nil } }
      )
    ) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text(model?.errorMessage ?? "未知错误")
    }
    .task(id: currentItem.id) {
      await prepareCurrentItem()
      await loadPlaylistIfNeeded()
    }
    .onChange(of: model?.didReachEnd ?? false) { _, ended in
      guard ended else { return }
      Task { @MainActor in
        if appState.autoPlayNextEpisode, nextItem != nil {
          playNextIfAvailable()
        } else {
          await model?.replay()
          controlsVisible = true
          scheduleControlsHide()
        }
      }
    }
    .onDisappear {
      hudTask?.cancel()
      controlsTask?.cancel()
      model?.pause()
      PlayerOrientation.request(.portrait)
    }
  }

  @ViewBuilder
  private var playerLayer: some View {
    if let model {
      if useVLC, let source = model.selectedSource, source.isOriginal,
        VLCAvailability.isAvailable
      {
        VLCPlayerView(source: source)
      } else {
        SystemPlayerView(player: model.player, videoLayout: videoLayout, showsPlaybackControls: false)
      }
    } else {
      ZStack {
        Color.black
        ProgressView("正在准备播放…")
          .tint(.white)
          .foregroundStyle(.white.opacity(0.8))
      }
    }
  }

  private func interactionLayer(proxy: GeometryProxy) -> some View {
    HStack(spacing: 0) {
      gestureSurface(isLeft: true, proxy: proxy)
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .frame(width: proxy.size.width * 0.34)
      gestureSurface(isLeft: false, proxy: proxy)
    }
    .ignoresSafeArea()
    .allowsHitTesting(!isLocked)
  }

  private func gestureSurface(isLeft: Bool, proxy: GeometryProxy) -> some View {
    let availableHeight = max(proxy.size.height, 1)
    let availableWidth = max(proxy.size.width, 1)

    return Color.clear
      .contentShape(Rectangle())
      .frame(maxWidth: .infinity)
      .onTapGesture { toggleControls() }
      .onTapGesture(count: 2) {
        guard appState.playerGesturesEnabled else { return }
        seekBy(isLeft ? -Double(appState.doubleTapSeekSeconds) : Double(appState.doubleTapSeekSeconds))
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 16)
          .onChanged { value in
            guard appState.playerGesturesEnabled else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            guard abs(dy) >= abs(dx) else { return }

            if !isGestureInteracting {
              isGestureInteracting = true
              controlsTask?.cancel()
              gestureStartBrightness = UIScreen.main.brightness
              gestureStartVolume = model?.player.volume
            }

            let normalizedDelta = -dy / availableHeight * 1.35
            if isLeft {
              let start = gestureStartBrightness ?? UIScreen.main.brightness
              let next = min(max(start + normalizedDelta, 0), 1)
              UIScreen.main.brightness = next
              showGestureHUD("亮度  \(Int(next * 100))%")
            } else if let model {
              let start = CGFloat(gestureStartVolume ?? model.player.volume)
              let next = min(max(start + normalizedDelta, 0), 1)
              model.player.volume = Float(next)
              showGestureHUD("音量  \(Int(next * 100))%")
            }
          }
          .onEnded { value in
            guard appState.playerGesturesEnabled else { return }
            let dx = value.translation.width
            let dy = value.translation.height

            if abs(dx) > abs(dy) {
              let delta = Double(dx / availableWidth) * 180
              if abs(delta) > 2 {
                seekBy(delta)
              }
            }

            gestureStartBrightness = nil
            gestureStartVolume = nil
            isGestureInteracting = false
            scheduleControlsHide()
          }
      )
  }

  private func lockShield(proxy: GeometryProxy) -> some View {
    ZStack(alignment: .leading) {
      Color.clear
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture { showGestureHUD("控制已锁定") }

      Button {
        isLocked = false
        controlsVisible = true
        showGestureHUD("已解锁")
        scheduleControlsHide()
      } label: {
        Image(systemName: "lock.open.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(.black.opacity(0.62), in: Circle())
      }
      .buttonStyle(.plain)
      .padding(.leading, 16)
    }
  }

  private func topOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height

    return HStack(spacing: landscape ? 9 : 8) {
      playerIconButton("xmark") {
        model?.pause()
        dismiss()
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(currentItem.name)
          .font(landscape ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        if landscape, playlist.count > 1 {
          Text("\(max(currentIndex + 1, 1)) / \(playlist.count)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.56))
        }
      }
      .layoutPriority(1)

      Spacer(minLength: 4)

      if let model {
        qualityMenu(model: model, compact: !landscape)
      }

      playerIconButton("rectangle.landscape.rotate") {
        controlsTask?.cancel()
        PlayerOrientation.request(landscape ? .portrait : .landscape)
        showGestureHUD(landscape ? "竖屏" : "横屏")
        scheduleControlsHide()
      }

      if landscape {
        playerIconButton("lock.fill") {
          isLocked = true
          controlsVisible = false
          showGestureHUD("控制已锁定")
        }
      }

      playerMoreMenu(model: model, landscape: landscape)
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, 12))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, 12))
    .padding(
      .top,
      (proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : (landscape ? 8 : 44))
        + (landscape ? 10 : 16)
    )
    .padding(.bottom, landscape ? 18 : 12)
    .background(
      LinearGradient(
        colors: [.black.opacity(0.78), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func playerMoreMenu(model: PlayerModel?, landscape: Bool) -> some View {
    Menu {
      if !landscape, let model {
        Section("清晰度") {
          ForEach(model.sources) { source in
            Button {
              Task {
                useVLC = shouldUseVLC(source)
                await model.select(source)
                model.setPlaybackRate(playbackRate)
                applyAutomaticOrientation(for: model.videoDisplaySize)
              }
            } label: {
              if model.selectedSource?.id == source.id {
                Label(source.title, systemImage: "checkmark")
              } else {
                Text(source.title)
              }
            }
          }
        }

        Section("播放速度") {
          ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
            Button(formatRate(rate)) {
              playbackRate = Float(rate)
              model.setPlaybackRate(Float(rate))
            }
          }
        }

        if !model.audioOptions.isEmpty {
          Section("音轨") {
            Button("自动") { model.selectAudio(nil) }
            ForEach(model.audioOptions) { option in
              Button(option.title) { model.selectAudio(option.id) }
            }
          }
        }

        Section("字幕") {
          Button("关闭字幕") { model.selectSubtitle(nil) }
          ForEach(model.subtitleOptions) { option in
            Button(option.title) { model.selectSubtitle(option.id) }
          }
        }
      }

      Section("画面") {
        Button(videoLayout == .fit ? "铺满屏幕" : "适应屏幕", systemImage: "rectangle.arrowtriangle.2.outward") {
          videoLayout = videoLayout == .fit ? .fill : .fit
          showGestureHUD(videoLayout.title)
        }
        Button("旋转屏幕", systemImage: "rectangle.landscape.rotate") {
          PlayerOrientation.toggle()
        }
        Button("锁定控制", systemImage: "lock.fill") {
          isLocked = true
          controlsVisible = false
          showGestureHUD("控制已锁定")
        }
      }

      if previousItem != nil {
        Button("上一个视频", systemImage: "backward.end.fill") { playPreviousIfAvailable() }
      }
      if nextItem != nil {
        Button("下一个视频", systemImage: "forward.end.fill") { playNextIfAvailable() }
      }

      Divider()
      Button("播放详情", systemImage: "info.circle") { showInfo = true }
    } label: {
      playerIcon("ellipsis")
    }
  }

  private func qualityMenu(model: PlayerModel, compact: Bool) -> some View {
    Menu {
      if model.sources.isEmpty {
        Text("正在取得清晰度…")
      } else {
        ForEach(model.sources) { source in
          Button {
            Task {
              useVLC = shouldUseVLC(source)
              await model.select(source)
              model.setPlaybackRate(playbackRate)
            }
          } label: {
            if model.selectedSource?.id == source.id {
              Label(source.title, systemImage: "checkmark")
            } else {
              Text(source.title)
            }
          }
        }
      }
    } label: {
      if compact {
        playerIcon("slider.horizontal.3")
      } else {
        playerPill(
          systemName: "slider.horizontal.3",
          text: model.selectedSource?.title ?? "清晰度"
        )
      }
    }
  }

  private func bottomOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height

    return VStack(spacing: landscape ? 11 : 9) {
      if model?.didFallbackFromOriginal == true {
        Label("原画不可播，已自动切换最高转码", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption.weight(.medium))
          .foregroundStyle(.white.opacity(0.86))
          .padding(.horizontal, 11)
          .padding(.vertical, 6)
          .background(.black.opacity(0.58), in: Capsule())
      }

      if let model {
        timeline(model: model)
        if landscape {
          landscapePlaybackControls(model: model)
        } else {
          portraitPlaybackControls(model: model)
        }
      }
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, 14))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, 14))
    .padding(.top, landscape ? 28 : 18)
    .padding(.bottom, max(proxy.safeAreaInsets.bottom, 10) + (landscape ? 2 : 6))
    .background(
      LinearGradient(
        colors: [.clear, .black.opacity(0.86)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func portraitPlaybackControls(model: PlayerModel) -> some View {
    HStack(spacing: 24) {
      controlCircle("gobackward.\(appState.doubleTapSeekSeconds)") {
        seekBy(-Double(appState.doubleTapSeekSeconds))
      }

      Button {
        model.togglePlayback()
        controlsVisible = true
        scheduleControlsHide()
      } label: {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 21, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: 54, height: 54)
          .background(.white, in: Circle())
      }
      .buttonStyle(.plain)

      controlCircle("goforward.\(appState.doubleTapSeekSeconds)") {
        seekBy(Double(appState.doubleTapSeekSeconds))
      }
    }
  }

  private func landscapePlaybackControls(model: PlayerModel) -> some View {
    VStack(spacing: 10) {
      HStack(spacing: 18) {
        controlCircle("backward.end.fill", enabled: previousItem != nil) {
          playPreviousIfAvailable()
        }
        controlCircle("gobackward.\(appState.doubleTapSeekSeconds)") {
          seekBy(-Double(appState.doubleTapSeekSeconds))
        }

        Button {
          model.togglePlayback()
          controlsVisible = true
          scheduleControlsHide()
        } label: {
          Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 56, height: 56)
            .background(.white, in: Circle())
        }
        .buttonStyle(.plain)

        controlCircle("goforward.\(appState.doubleTapSeekSeconds)") {
          seekBy(Double(appState.doubleTapSeekSeconds))
        }
        controlCircle("forward.end.fill", enabled: nextItem != nil) {
          playNextIfAvailable()
        }
      }

      HStack(spacing: 8) {
        speedMenu(model: model)
        audioMenu(model: model)
        subtitleMenu(model: model)

        Button {
          videoLayout = videoLayout == .fit ? .fill : .fit
          showGestureHUD(videoLayout.title)
        } label: {
          playerPill(
            systemName: videoLayout == .fit ? "arrow.up.left.and.arrow.down.right" : "rectangle.inset.filled",
            text: videoLayout.title
          )
        }
        .buttonStyle(.plain)

        Spacer(minLength: 4)

        Button {
          appState.libraryStore.toggleFavorite(currentItem)
        } label: {
          playerPill(
            systemName: appState.libraryStore.isFavorite(currentItem) ? "heart.fill" : "heart",
            text: appState.libraryStore.isFavorite(currentItem) ? "已收藏" : "收藏"
          )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func timeline(model: PlayerModel) -> some View {
    VStack(spacing: 5) {
      Slider(
        value: Binding(
          get: { isScrubbing ? scrubValue : model.currentTime },
          set: { scrubValue = $0 }
        ),
        in: 0...max(model.duration, 1),
        onEditingChanged: { editing in
          isScrubbing = editing
          if editing {
            scrubValue = model.currentTime
            controlsTask?.cancel()
          } else {
            model.seek(to: scrubValue)
            scheduleControlsHide()
          }
        }
      )
      .tint(CinevaTheme.accent)

      HStack {
        Text(formatTime(isScrubbing ? scrubValue : model.currentTime))
        Spacer()
        if model.bufferedUntil > model.currentTime + 1 {
          Text("已缓冲 \(formatTime(model.bufferedUntil))")
            .foregroundStyle(.white.opacity(0.46))
        }
        Spacer()
        Text(formatTime(model.duration))
      }
      .font(.caption2.monospacedDigit().weight(.medium))
      .foregroundStyle(.white.opacity(0.72))
    }
  }

  private func speedMenu(model: PlayerModel) -> some View {
    Menu {
      ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
        Button {
          playbackRate = Float(rate)
          model.setPlaybackRate(Float(rate))
          showGestureHUD(formatRate(rate))
        } label: {
          if abs(Double(playbackRate) - rate) < 0.001 {
            Label(formatRate(rate), systemImage: "checkmark")
          } else {
            Text(formatRate(rate))
          }
        }
      }
    } label: {
      playerPill(systemName: "speedometer", text: formatRate(Double(playbackRate)))
    }
  }

  private func audioMenu(model: PlayerModel) -> some View {
    Menu {
      if model.audioOptions.isEmpty {
        Text("当前视频没有可切换音轨")
      } else {
        Button("自动") { model.selectAudio(nil) }
        Divider()
        ForEach(model.audioOptions) { option in
          Button {
            model.selectAudio(option.id)
          } label: {
            if model.selectedAudioOptionID == option.id {
              Label(option.title, systemImage: "checkmark")
            } else {
              Text(option.title)
            }
          }
        }
      }
    } label: {
      playerPill(systemName: "waveform", text: "音轨")
    }
  }

  private func subtitleMenu(model: PlayerModel) -> some View {
    Menu {
      Button("关闭字幕") { model.selectSubtitle(nil) }
      if !model.subtitleOptions.isEmpty {
        Divider()
        ForEach(model.subtitleOptions) { option in
          Button {
            model.selectSubtitle(option.id)
          } label: {
            if model.selectedSubtitleOptionID == option.id {
              Label(option.title, systemImage: "checkmark")
            } else {
              Text(option.title)
            }
          }
        }
      }
    } label: {
      playerPill(systemName: "captions.bubble", text: "字幕")
    }
  }

  private func controlCircle(
    _ systemName: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(enabled ? .white : .white.opacity(0.28))
        .frame(width: 44, height: 44)
        .background(.white.opacity(enabled ? 0.10 : 0.05), in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private func playerIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { playerIcon(systemName) }
      .buttonStyle(.plain)
  }

  private func playerIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 38, height: 38)
      .background(.black.opacity(0.50), in: Circle())
      .contentShape(Circle())
  }

  private func playerPill(systemName: String, text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemName)
      Text(text).lineLimit(1)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .frame(height: 36)
    .background(.white.opacity(0.10), in: Capsule())
  }

  @MainActor
  private func prepareCurrentItem() async {
    controlsTask?.cancel()
    PlayerOrientation.request(.portrait)
    model?.pause()

    let newModel = PlayerModel(
      item: currentItem,
      api: appState.api,
      libraryStore: appState.libraryStore,
      defaultQuality: appState.defaultQuality
    )
    model = newModel
    newModel.setPlaybackRate(playbackRate)
    await newModel.prepareAndPlay()

    if let selected = newModel.selectedSource {
      useVLC = shouldUseVLC(selected)
    } else {
      useVLC = false
    }

    applyAutomaticOrientation(for: newModel.videoDisplaySize)
    controlsVisible = true
    scheduleControlsHide()
  }

  @MainActor
  private func applyAutomaticOrientation(for size: CGSize?) {
    guard let size, size.width > 0, size.height > 0 else {
      PlayerOrientation.request(.portrait)
      return
    }
    let ratio = size.width / max(size.height, 1)
    PlayerOrientation.request(ratio > 1.12 ? .landscape : .portrait)
  }

  @MainActor
  private func loadPlaylistIfNeeded() async {
    guard !currentItem.parentID.isEmpty else {
      playlist = [currentItem]
      return
    }
    guard loadedPlaylistParentID != currentItem.parentID else { return }
    do {
      let siblings = try await appState.api.listFolder(id: currentItem.parentID)
        .filter { !$0.isDirectory && $0.isVideo }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      playlist = siblings.isEmpty ? [currentItem] : siblings
      loadedPlaylistParentID = currentItem.parentID
    } catch {
      playlist = [currentItem]
    }
  }

  private var currentIndex: Int {
    playlist.firstIndex(where: { $0.id == currentItem.id }) ?? 0
  }

  private var previousItem: CloudItem? {
    let index = currentIndex
    guard !playlist.isEmpty, index > 0 else { return nil }
    return playlist[index - 1]
  }

  private var nextItem: CloudItem? {
    let index = currentIndex
    guard !playlist.isEmpty, index + 1 < playlist.count else { return nil }
    return playlist[index + 1]
  }

  private func playPreviousIfAvailable() {
    guard let previousItem else { return }
    switchTo(previousItem)
  }

  private func playNextIfAvailable() {
    guard let nextItem else { return }
    switchTo(nextItem)
  }

  private func switchTo(_ item: CloudItem) {
    model?.pause()
    model = nil
    useVLC = false
    currentItem = item
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }

  @MainActor
  private func seekBy(_ seconds: Double) {
    guard let model else { return }
    model.seekBy(seconds)
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    let magnitude = Int(abs(seconds).rounded())
    showGestureHUD(seconds < 0 ? "⏪  \(magnitude) 秒" : "\(magnitude) 秒  ⏩")
    scheduleControlsHide()
  }

  @MainActor
  private func toggleControls() {
    guard !isLocked else { return }
    withAnimation(.easeOut(duration: 0.18)) {
      controlsVisible.toggle()
    }
    if controlsVisible {
      scheduleControlsHide()
    } else {
      controlsTask?.cancel()
    }
  }

  @MainActor
  private func scheduleControlsHide() {
    controlsTask?.cancel()
    guard model?.isPlaying == true, !isLocked, !isScrubbing, !isGestureInteracting else { return }
    controlsTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2.0))
      guard !Task.isCancelled else { return }
      withAnimation(.easeIn(duration: 0.22)) {
        controlsVisible = false
      }
    }
  }

  @MainActor
  private func showGestureHUD(_ message: String) {
    hudTask?.cancel()
    withAnimation(.easeOut(duration: 0.16)) {
      gestureHUD = message
    }
    hudTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(950))
      guard !Task.isCancelled else { return }
      withAnimation(.easeIn(duration: 0.18)) {
        gestureHUD = nil
      }
    }
  }

  private func formatRate(_ rate: Double) -> String {
    rate == floor(rate) ? String(format: "%.0fx", rate) : String(format: "%gx", rate)
  }

  private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = max(0, Int(seconds.rounded()))
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%02d:%02d", minutes, secs)
  }

  private func shouldUseVLC(_ source: VideoSource) -> Bool {
    source.isOriginal && currentItem.prefersVLCForOriginal && VLCAvailability.isAvailable
  }
}

private struct PlayerInfoSheet: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let model: PlayerModel?
  let videoLayout: PlayerVideoLayout
  let playbackRate: Float
  let playlistCount: Int

  var body: some View {
    NavigationStack {
      List {
        Section("视频") {
          LabeledContent("名称", value: item.name)
          LabeledContent("大小", value: item.formattedSize)
          if !item.formattedDuration.isEmpty {
            LabeledContent("时长", value: item.formattedDuration)
          }
          if !item.fileExtension.isEmpty {
            LabeledContent("格式", value: item.fileExtension.uppercased())
          }
        }

        Section("播放") {
          LabeledContent("当前清晰度", value: model?.selectedSource?.title ?? "读取中")
          LabeledContent("画面模式", value: videoLayout.title)
          LabeledContent("播放速度", value: playbackRate == 1 ? "1x" : String(format: "%gx", playbackRate))
          LabeledContent("同目录队列", value: "\(playlistCount) 个视频")
          LabeledContent("音轨", value: "\(model?.audioOptions.count ?? 0) 个可选")
          LabeledContent("字幕", value: "\(model?.subtitleOptions.count ?? 0) 个可选")
          LabeledContent("画中画", value: "支持")
        }

        Section("手势") {
          LabeledContent("双击快进/快退", value: "\(appState.doubleTapSeekSeconds) 秒")
          LabeledContent("左右滑动", value: "快进 / 快退")
          LabeledContent("左侧上下滑", value: "亮度")
          LabeledContent("右侧上下滑", value: "播放音量")
        }

        Section {
          Button {
            appState.libraryStore.toggleFavorite(item)
          } label: {
            Label(
              appState.libraryStore.isFavorite(item) ? "取消收藏" : "收藏这个视频",
              systemImage: appState.libraryStore.isFavorite(item) ? "heart.slash" : "heart"
            )
          }
        }
      }
      .navigationTitle("播放详情")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private enum PlayerOrientation {
  @MainActor
  static func toggle() {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    else { return }

    let current = scene.interfaceOrientation
    request(current.isPortrait ? .landscape : .portrait, scene: scene)
  }

  @MainActor
  static func request(_ orientations: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    else { return }
    request(orientations, scene: scene)
  }

  @MainActor
  private static func request(_ orientations: UIInterfaceOrientationMask, scene: UIWindowScene) {
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
  }
}
