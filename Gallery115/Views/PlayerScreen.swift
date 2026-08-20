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
  @State private var showSettingsPanel = false
  @State private var gestureHUD: String?
  @State private var hudTask: Task<Void, Never>?
  @State private var controlsTask: Task<Void, Never>?
  @State private var scrubValue: Double = 0
  @State private var isScrubbing = false
  @State private var isGestureInteracting = false
  @State private var isControlsInteractionActive = false
  @State private var gestureStartBrightness: CGFloat?
  @State private var gestureStartVolume: Float?

  init(item: CloudItem, playlist: [CloudItem] = []) {
    _currentItem = State(initialValue: item)
    let videos = playlist.filter { !$0.isDirectory && $0.isVideo }
    let normalized: [CloudItem]
    if videos.isEmpty {
      normalized = [item]
    } else if videos.contains(where: { $0.id == item.id }) {
      normalized = videos
    } else {
      normalized = videos + [item]
    }
    _playlist = State(initialValue: normalized)
    _loadedPlaylistParentID = State(initialValue: playlist.isEmpty ? nil : item.parentID)
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
          playerChrome(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .transition(.opacity)
        }

        if showSettingsPanel, !isLocked {
          settingsOverlay(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .zIndex(20)
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
    .onChange(of: showInfo) { _, presented in
      if presented {
        controlsTask?.cancel()
        controlsVisible = true
      } else {
        scheduleControlsHide()
      }
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
      showSettingsPanel = false
      isControlsInteractionActive = false
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

  @ViewBuilder
  private func playerChrome(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height

    ZStack {
      VStack(spacing: 0) {
        topOverlay(proxy: proxy)
        Spacer(minLength: 0)
        bottomOverlay(proxy: proxy)
      }

      if let model {
        if landscape {
          landscapeCenterTransport(model: model)
        } else {
          portraitCenterTransport(model: model)
            .offset(y: -8)
        }
      }
    }
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

    return HStack(spacing: landscape ? 10 : 9) {
      playerIconButton("xmark") {
        model?.pause()
        dismiss()
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(currentItem.name)
          .font(landscape ? .subheadline.weight(.semibold) : .subheadline.weight(.semibold))
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

      if let model, model.sources.count > 1 {
        Button {
          openSettingsPanel()
        } label: {
          if landscape {
            playerPill(
              systemName: "slider.horizontal.3",
              text: model.selectedSource?.title ?? "清晰度"
            )
          } else {
            playerIcon("slider.horizontal.3")
          }
        }
        .buttonStyle(.plain)
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

      playerIconButton("ellipsis") {
        openSettingsPanel()
      }
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, 12))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, 12))
    .padding(
      .top,
      landscape
        ? max(proxy.safeAreaInsets.top + 8, 16)
        : max(proxy.safeAreaInsets.top + 12, 54)
    )
    .padding(.bottom, landscape ? 18 : 12)
    .background(
      LinearGradient(
        colors: [.black.opacity(landscape ? 0.50 : 0.64), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func settingsOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height

    return ZStack(alignment: landscape ? .trailing : .bottom) {
      Color.black.opacity(0.30)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { closeSettingsPanel() }

      settingsPanel(proxy: proxy)
        .padding(.trailing, landscape ? max(proxy.safeAreaInsets.trailing, 18) : 12)
        .padding(.leading, landscape ? 12 : 12)
        .padding(.bottom, landscape ? 0 : max(proxy.safeAreaInsets.bottom, 12))
    }
    .onTapGesture {
      controlsTask?.cancel()
      controlsVisible = true
    }
  }

  private func settingsPanel(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height
    let panelWidth = landscape ? min(340.0, proxy.size.width * 0.42) : max(proxy.size.width - 24, 280)
    let panelHeight = landscape ? min(proxy.size.height * 0.82, 470) : min(proxy.size.height * 0.64, 560)

    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("播放设置")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
          Text(currentItem.name)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.54))
            .lineLimit(1)
        }
        Spacer()
        Button { closeSettingsPanel() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.86))
            .frame(width: 32, height: 32)
            .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)
      .padding(.bottom, 12)

      Divider().overlay(.white.opacity(0.08))

      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 18) {
          if let model {
            settingsSpeedSection(model: model)

            if model.sources.count > 1 {
              settingsQualitySection(model: model)
            }

            settingsAudioSection(model: model)
            settingsSubtitleSection(model: model)
          }

          settingsPictureSection()
          settingsOtherSection()
        }
        .padding(18)
      }
    }
    .frame(width: panelWidth, height: panelHeight)
    .background(.black.opacity(0.88))
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: landscape ? 20 : 24, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: landscape ? 20 : 24, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 0.8)
    }
    .shadow(color: .black.opacity(0.35), radius: 26, y: 10)
  }

  private func settingsSpeedSection(model: PlayerModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("播放速度")
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
          settingsChip(
            formatRate(rate),
            selected: abs(Double(playbackRate) - rate) < 0.001
          ) {
            playbackRate = Float(rate)
            model.setPlaybackRate(Float(rate))
            keepControlsDuringInteraction()
          }
        }
      }
    }
  }

  private func settingsQualitySection(model: PlayerModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("清晰度")
      VStack(spacing: 6) {
        ForEach(model.sources) { source in
          settingsRow(
            title: source.title,
            systemName: source.isOriginal ? "sparkles.tv" : "play.rectangle",
            selected: model.selectedSource?.id == source.id
          ) {
            keepControlsDuringInteraction()
            Task { @MainActor in
              useVLC = shouldUseVLC(source)
              await model.select(source)
              model.setPlaybackRate(playbackRate)
              applyAutomaticOrientation(for: model.videoDisplaySize)
              keepControlsDuringInteraction()
            }
          }
        }
      }
    }
  }

  private func settingsAudioSection(model: PlayerModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("音轨")
      if model.audioOptions.isEmpty {
        settingsUnavailableRow("当前视频没有可切换音轨", systemName: "waveform")
      } else {
        settingsRow(title: "自动", systemName: "waveform", selected: model.selectedAudioOptionID == nil) {
          model.selectAudio(nil)
          keepControlsDuringInteraction()
        }
        ForEach(model.audioOptions) { option in
          settingsRow(
            title: option.title,
            systemName: "waveform",
            selected: model.selectedAudioOptionID == option.id
          ) {
            model.selectAudio(option.id)
            keepControlsDuringInteraction()
          }
        }
      }
    }
  }

  private func settingsSubtitleSection(model: PlayerModel) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("字幕")
      settingsRow(title: "关闭字幕", systemName: "captions.bubble", selected: model.selectedSubtitleOptionID == nil) {
        model.selectSubtitle(nil)
        keepControlsDuringInteraction()
      }
      ForEach(model.subtitleOptions) { option in
        settingsRow(
          title: option.title,
          systemName: "captions.bubble",
          selected: model.selectedSubtitleOptionID == option.id
        ) {
          model.selectSubtitle(option.id)
          keepControlsDuringInteraction()
        }
      }
    }
  }

  private func settingsPictureSection() -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("画面")
      HStack(spacing: 8) {
        settingsActionButton(
          videoLayout.title,
          systemName: videoLayout == .fit ? "rectangle.inset.filled" : "arrow.up.left.and.arrow.down.right"
        ) {
          videoLayout = videoLayout == .fit ? .fill : .fit
          keepControlsDuringInteraction()
        }
        settingsActionButton("旋转", systemName: "rectangle.landscape.rotate") {
          PlayerOrientation.toggle()
          keepControlsDuringInteraction()
        }
      }
    }
  }

  private func settingsOtherSection() -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("更多")

      if previousItem != nil || nextItem != nil {
        HStack(spacing: 8) {
          settingsActionButton("上一个", systemName: "backward.end.fill", enabled: previousItem != nil) {
            closeSettingsPanel(scheduleHide: false)
            playPreviousIfAvailable()
          }
          settingsActionButton("下一个", systemName: "forward.end.fill", enabled: nextItem != nil) {
            closeSettingsPanel(scheduleHide: false)
            playNextIfAvailable()
          }
        }
      }

      HStack(spacing: 8) {
        settingsActionButton(
          appState.libraryStore.isFavorite(currentItem) ? "已收藏" : "收藏",
          systemName: appState.libraryStore.isFavorite(currentItem) ? "heart.fill" : "heart"
        ) {
          appState.libraryStore.toggleFavorite(currentItem)
          keepControlsDuringInteraction()
        }
        settingsActionButton("详情", systemName: "info.circle") {
          closeSettingsPanel(scheduleHide: false)
          showInfo = true
        }
      }

      settingsActionButton("锁定控制", systemName: "lock.fill") {
        showSettingsPanel = false
        isLocked = true
        controlsVisible = false
        controlsTask?.cancel()
        showGestureHUD("控制已锁定")
      }
    }
  }

  private func settingsSectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white.opacity(0.56))
  }

  private func settingsChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(selected ? .white.opacity(0.18) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          if selected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(.white.opacity(0.22), lineWidth: 0.8)
          }
        }
    }
    .buttonStyle(.plain)
  }

  private func settingsRow(
    title: String,
    systemName: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 11) {
        Image(systemName: systemName)
          .font(.system(size: 14, weight: .medium))
          .frame(width: 20)
        Text(title)
          .font(.subheadline)
          .lineLimit(1)
        Spacer()
        if selected {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
        }
      }
      .foregroundStyle(.white.opacity(selected ? 1 : 0.86))
      .padding(.horizontal, 12)
      .frame(height: 42)
      .background(selected ? .white.opacity(0.12) : .white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func settingsUnavailableRow(_ title: String, systemName: String) -> some View {
    HStack(spacing: 11) {
      Image(systemName: systemName).frame(width: 20)
      Text(title).lineLimit(1)
      Spacer()
    }
    .font(.subheadline)
    .foregroundStyle(.white.opacity(0.42))
    .padding(.horizontal, 12)
    .frame(height: 42)
    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func settingsActionButton(
    _ title: String,
    systemName: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: systemName)
        Text(title).lineLimit(1)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(enabled ? .white : .white.opacity(0.28))
      .frame(maxWidth: .infinity)
      .frame(height: 40)
      .background(.white.opacity(enabled ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private func bottomOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height

    return VStack(spacing: landscape ? 8 : 10) {
      if model?.didFallbackFromOriginal == true {
        Label("原画不可播，已自动切换最高转码", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption.weight(.medium))
          .foregroundStyle(.white.opacity(0.86))
          .padding(.horizontal, 11)
          .padding(.vertical, 6)
          .background(.black.opacity(0.50), in: Capsule())
      }

      if let model {
        timeline(model: model)
        if landscape {
          landscapeUtilityBar(model: model)
        } else {
          portraitUtilityBar(model: model)
        }
      }
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, landscape ? 24 : 16))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, landscape ? 24 : 16))
    .padding(.top, landscape ? 42 : 34)
    .padding(.bottom, max(proxy.safeAreaInsets.bottom, landscape ? 10 : 14) + 4)
    .background(
      LinearGradient(
        colors: [.clear, .black.opacity(landscape ? 0.66 : 0.76)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func portraitCenterTransport(model: PlayerModel) -> some View {
    HStack(spacing: 34) {
      centerTransportButton("gobackward.\(appState.doubleTapSeekSeconds)", size: 19) {
        seekBy(-Double(appState.doubleTapSeekSeconds))
      }

      Button {
        model.togglePlayback()
        controlsVisible = true
        scheduleControlsHide()
      } label: {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: 62, height: 62)
          .background(.white, in: Circle())
          .shadow(color: .black.opacity(0.30), radius: 14, y: 5)
      }
      .buttonStyle(.plain)

      centerTransportButton("goforward.\(appState.doubleTapSeekSeconds)", size: 19) {
        seekBy(Double(appState.doubleTapSeekSeconds))
      }
    }
  }

  private func portraitUtilityBar(model: PlayerModel) -> some View {
    HStack(spacing: 8) {
      utilityButton(title: formatRate(Double(playbackRate)), systemName: "speedometer") {
        openSettingsPanel()
      }

      utilityIconButton("backward.end.fill", enabled: previousItem != nil) {
        playPreviousIfAvailable()
      }

      utilityIconButton("forward.end.fill", enabled: nextItem != nil) {
        playNextIfAvailable()
      }

      Spacer(minLength: 8)

      utilityIconButton(videoLayout == .fit ? "rectangle.inset.filled" : "arrow.up.left.and.arrow.down.right") {
        videoLayout = videoLayout == .fit ? .fill : .fit
        showGestureHUD(videoLayout.title)
        scheduleControlsHide()
      }

      utilityIconButton(appState.libraryStore.isFavorite(currentItem) ? "heart.fill" : "heart") {
        appState.libraryStore.toggleFavorite(currentItem)
        scheduleControlsHide()
      }

      utilityIconButton("ellipsis") {
        openSettingsPanel()
      }
    }
  }

  private func landscapeCenterTransport(model: PlayerModel) -> some View {
    HStack(spacing: 30) {
      centerTransportButton("backward.end.fill", enabled: previousItem != nil, size: 18) {
        playPreviousIfAvailable()
      }

      centerTransportButton("gobackward.\(appState.doubleTapSeekSeconds)", size: 20) {
        seekBy(-Double(appState.doubleTapSeekSeconds))
      }

      Button {
        model.togglePlayback()
        controlsVisible = true
        scheduleControlsHide()
      } label: {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 27, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: 68, height: 68)
          .background(.white, in: Circle())
          .shadow(color: .black.opacity(0.34), radius: 16, y: 6)
      }
      .buttonStyle(.plain)

      centerTransportButton("goforward.\(appState.doubleTapSeekSeconds)", size: 20) {
        seekBy(Double(appState.doubleTapSeekSeconds))
      }

      centerTransportButton("forward.end.fill", enabled: nextItem != nil, size: 18) {
        playNextIfAvailable()
      }
    }
  }

  private func centerTransportButton(
    _ systemName: String,
    enabled: Bool = true,
    size: CGFloat = 20,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(enabled ? .white : .white.opacity(0.24))
        .frame(width: 46, height: 46)
        .background(.black.opacity(enabled ? 0.28 : 0.18), in: Circle())
        .overlay {
          Circle().stroke(.white.opacity(enabled ? 0.08 : 0.04), lineWidth: 0.6)
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private func landscapeUtilityBar(model: PlayerModel) -> some View {
    HStack(spacing: 8) {
      utilityButton(title: formatRate(Double(playbackRate)), systemName: "speedometer") {
        openSettingsPanel()
      }

      utilityButton(title: "音轨", systemName: "waveform") { openSettingsPanel() }
      utilityButton(title: "字幕", systemName: "captions.bubble") { openSettingsPanel() }

      utilityIconButton(videoLayout == .fit ? "rectangle.inset.filled" : "arrow.up.left.and.arrow.down.right") {
        videoLayout = videoLayout == .fit ? .fill : .fit
        showGestureHUD(videoLayout.title)
        scheduleControlsHide()
      }

      Spacer(minLength: 12)

      utilityIconButton(appState.libraryStore.isFavorite(currentItem) ? "heart.fill" : "heart") {
        appState.libraryStore.toggleFavorite(currentItem)
        scheduleControlsHide()
      }

      utilityIconButton("info.circle") {
        controlsTask?.cancel()
        controlsVisible = true
        showInfo = true
      }
    }
  }

  private func utilityButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: systemName)
        Text(title)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white.opacity(0.88))
      .padding(.horizontal, 10)
      .frame(height: 34)
      .background(.white.opacity(0.075), in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private func utilityIconButton(
    _ systemName: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(enabled ? .white.opacity(0.88) : .white.opacity(0.24))
        .frame(width: 34, height: 34)
        .background(.white.opacity(enabled ? 0.07 : 0.035), in: Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private func timeline(model: PlayerModel) -> some View {
    VStack(spacing: 5) {
      GeometryReader { proxy in
        let width = max(proxy.size.width, 1)
        let duration = max(model.duration, 1)
        let current = min(max(isScrubbing ? scrubValue : model.currentTime, 0), duration)
        let buffered = min(max(model.bufferedUntil, 0), duration)
        let playedProgress = CGFloat(current / duration)
        let bufferedProgress = CGFloat(buffered / duration)
        let playedX = width * playedProgress
        let bufferedX = width * bufferedProgress

        ZStack(alignment: .leading) {
          Capsule()
            .fill(.white.opacity(0.20))
            .frame(height: 3)

          Capsule()
            .fill(.white.opacity(0.32))
            .frame(width: bufferedX, height: 3)

          Capsule()
            .fill(CinevaTheme.accent)
            .frame(width: playedX, height: 3)

          Circle()
            .fill(.white)
            .frame(width: isScrubbing ? 10 : 8, height: isScrubbing ? 10 : 8)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .offset(x: min(max(playedX - (isScrubbing ? 5 : 4), 0), max(width - (isScrubbing ? 10 : 8), 0)))
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              if !isScrubbing {
                isScrubbing = true
                controlsTask?.cancel()
              }
              let x = min(max(value.location.x, 0), width)
              scrubValue = Double(x / width) * duration
            }
            .onEnded { value in
              let x = min(max(value.location.x, 0), width)
              scrubValue = Double(x / width) * duration
              model.seek(to: scrubValue)
              isScrubbing = false
              scheduleControlsHide()
            }
        )
      }
      .frame(height: 28)

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

  private var controlsInteractionGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        beginControlsInteraction()
      }
      .onEnded { _ in
        endControlsInteraction()
      }
  }

  @MainActor
  private func beginControlsInteraction() {
    isControlsInteractionActive = true
    controlsTask?.cancel()
    controlsVisible = true
  }

  @MainActor
  private func endControlsInteraction() {
    isControlsInteractionActive = false
    scheduleControlsHide()
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
    showSettingsPanel = false
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
  private func openSettingsPanel() {
    controlsTask?.cancel()
    controlsVisible = true
    withAnimation(.easeOut(duration: 0.18)) {
      showSettingsPanel = true
    }
  }

  @MainActor
  private func closeSettingsPanel(scheduleHide: Bool = true) {
    withAnimation(.easeIn(duration: 0.16)) {
      showSettingsPanel = false
    }
    if scheduleHide {
      scheduleControlsHide()
    }
  }

  @MainActor
  private func keepControlsDuringInteraction() {
    controlsTask?.cancel()
    controlsVisible = true
  }

  @MainActor
  private func scheduleControlsHide() {
    controlsTask?.cancel()
    guard model?.isPlaying == true, !isLocked, !isScrubbing, !isGestureInteracting, !isControlsInteractionActive, !showSettingsPanel, !showInfo else { return }
    controlsTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2.0))
      guard !Task.isCancelled, !showSettingsPanel, !showInfo, !isScrubbing, !isGestureInteracting, !isControlsInteractionActive else { return }
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
