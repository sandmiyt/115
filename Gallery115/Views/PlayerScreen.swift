import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

struct PlayerScreen: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState

  @State private var currentItem: CloudItem
  @State private var playlist: [CloudItem] = []
  @State private var loadedPlaylistParentID: String?
  @State private var model: PlayerModel?
  @State private var vlcController = VLCPlaybackController()
  @State private var systemPresentationController = SystemPlayerPresentationController()
  @State private var useVLC = false
  @State private var didLoadPreferredRate = false
  @State private var localMetadata: LocalMediaMetadata?
  @State private var showInfo = false
  @State private var videoLayout: PlayerVideoLayout = .fit
  @State private var playbackRate: Float = 1.0
  @State private var isLocked = false
  @State private var controlsVisible = true
  @State private var showSettingsPanel = false
  @State private var showSpeedPanel = false
  @State private var showQueuePanel = false
  @State private var showPlaybackHUD = false
  @State private var isRoutePickerPresented = false
  @State private var gestureHUD: String?
  @State private var showFavoriteHeart = false
  @State private var hudTask: Task<Void, Never>?
  @State private var favoriteHUDTask: Task<Void, Never>?
  @State private var controlsTask: Task<Void, Never>?
  @State private var scrubValue: Double = 0
  @State private var isScrubbing = false
  @State private var isGestureInteracting = false
  @State private var isControlsInteractionActive = false
  @State private var gestureStartBrightness: CGFloat?
  @State private var gestureStartVolume: Float?
  @State private var videoScale: CGFloat = 1.0
  @State private var pinchStartScale: CGFloat = 1.0
  @State private var isPinchInteracting = false
  @State private var externalSubtitleTracks: [ExternalSubtitleTrack] = []
  @State private var selectedExternalSubtitleID: String?
  @State private var externalSubtitleCues: [SubtitleCue] = []
  @State private var sidecarChapters: [PlayerChapter] = []
  @State private var timelinePreviewImage: UIImage?
  @State private var timelinePreviewBucket = -1
  @State private var timelinePreviewTask: Task<Void, Never>?
  @State private var subtitleLoadTask: Task<Void, Never>?
  @State private var auxiliaryLoadTask: Task<Void, Never>?

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
    _loadedPlaylistParentID = State(initialValue: nil)
  }

  var body: some View {
    playbackObservedView
  }

  private var playerBaseView: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black.ignoresSafeArea()

        playerLayer
          .frame(width: proxy.size.width, height: proxy.size.height)
          .scaleEffect(videoScale, anchor: .center)
          .background(Color.black)
          .clipped()
          .ignoresSafeArea()

        interactionLayer(proxy: proxy)

        if let subtitleText = activeExternalSubtitleText {
          externalSubtitleOverlay(text: subtitleText, proxy: proxy)
            .zIndex(8)
        }

        if !isLocked, appState.isAppUnlocked {
          skipSegmentOverlay(proxy: proxy)
            .zIndex(9)
        }

        if isLocked {
          lockShield(proxy: proxy)
        } else {
          playerChrome(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .opacity(chromeShouldBeVisible ? 1 : 0)
            .allowsHitTesting(chromeShouldBeVisible && !showSettingsPanel && !showSpeedPanel && !showQueuePanel)
            .accessibilityHidden(!chromeShouldBeVisible)
        }

        if showSettingsPanel, !isLocked {
          settingsOverlay(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            .zIndex(20)
        }

        if showSpeedPanel, !isLocked {
          speedOverlay(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
            .zIndex(21)
        }

        if showQueuePanel, !isLocked {
          queueOverlay(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .transition(.opacity.combined(with: .move(edge: proxy.size.width > proxy.size.height ? .trailing : .bottom)))
            .zIndex(22)
        }

        if showPlaybackHUD, !isLocked {
          playbackHUD(proxy: proxy)
            .transition(.opacity)
            .zIndex(15)
        }

        if activeIsBuffering {
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

        if showFavoriteHeart {
          Image(systemName: "heart.fill")
            .font(.system(size: 72, weight: .bold))
            .foregroundStyle(.red)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .transition(.scale(scale: 0.55).combined(with: .opacity))
            .allowsHitTesting(false)
            .zIndex(40)
        }

        if appState.faceIDEnabled && !appState.isAppUnlocked {
          ZStack {
            Rectangle()
              .fill(.regularMaterial)
              .overlay(Color.black.opacity(0.12))
              .ignoresSafeArea()

            VStack(spacing: 12) {
              Image(systemName: "faceid")
                .font(.system(size: 34, weight: .medium))
              Text("点击重新验证")
                .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
          }
          .contentShape(Rectangle())
          .onTapGesture {
            Task { await appState.authenticateIfNeeded() }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Cineva 已锁定，点击重新验证")
          .zIndex(10_000)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .animation(.easeInOut(duration: chromeShouldBeVisible ? 0.18 : 0.26), value: chromeShouldBeVisible)
      .animation(.easeInOut(duration: 0.18), value: showPlaybackHUD)
    }
    .background(Color.black)
    .ignoresSafeArea()
    .statusBarHidden(true)
  }

  private var playerPresentationView: some View {
    playerBaseView
    .sheet(isPresented: $showInfo) {
      PlayerInfoSheet(
        item: currentItem,
        model: model,
        videoLayout: videoLayout,
        playbackRate: playbackRate,
        playlistCount: playlist.count,
        localMetadata: localMetadata,
        networkMbps: activeNetworkMbps,
        bufferedDuration: activeBufferedDuration,
        playbackEngine: useVLC ? "VLC" : "AVPlayer"
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
    .onChange(of: appState.isAppUnlocked) { _, unlocked in
      if !unlocked, appState.faceIDEnabled {
        // A SwiftUI sheet is presented above the full-screen player. Dismiss it
        // immediately when privacy lock engages so playback details cannot remain
        // visible in the app switcher above the player's blur shield.
        showInfo = false
        showSettingsPanel = false
        showSpeedPanel = false
        showQueuePanel = false
        showPlaybackHUD = false
        controlsTask?.cancel()
        controlsVisible = false
      } else if unlocked {
        showControls(animated: false)
        scheduleControlsHide()
      }
    }
    .onChange(of: showSettingsPanel) { _, presented in
      handleInteractiveOverlayChange(presented)
    }
    .onChange(of: showSpeedPanel) { _, presented in
      handleInteractiveOverlayChange(presented)
    }
    .onChange(of: showQueuePanel) { _, presented in
      handleInteractiveOverlayChange(presented)
    }
    .onChange(of: showPlaybackHUD) { _, presented in
      handleInteractiveOverlayChange(presented)
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
  }

  private var playbackObservedView: some View {
    playerPresentationView
    .task(id: currentItem.id) {
      await prepareCurrentItem()
    }
    .onChange(of: model?.requiresVLC ?? false) { _, requiresVLC in
      guard requiresVLC, !useVLC, let model else { return }
      activatePlaybackEngine(for: model)
      configureRemotePlayback()
      updateRemotePlaybackInfo()
    }
    .onChange(of: activeCurrentTime) { _, _ in
      updateRemotePlaybackInfo()
    }
    .onChange(of: activeIsPlaying) { _, playing in
      updateRemotePlaybackInfo()
      if playing {
        scheduleControlsHide()
      } else {
        controlsTask?.cancel()
        showControls(animated: true)
      }
    }
    .onChange(of: localMetadata?.displayTitle(fallback: currentItem.name)) { _, _ in
      configureRemotePlayback()
      updateRemotePlaybackInfo()
    }
    .onChange(of: activeDidReachEnd) { _, ended in
      guard ended else { return }
      Task { @MainActor in
        if appState.autoPlayNextEpisode, nextItem != nil {
          playNextIfAvailable()
        } else {
          replayActivePlayer()
          showControls(animated: true)
          scheduleControlsHide()
        }
      }
    }
    .onDisappear(perform: handlePlayerDisappear)
  }


  private func handlePlayerDisappear() {
    showSettingsPanel = false
    showSpeedPanel = false
    showQueuePanel = false
    isControlsInteractionActive = false
    hudTask?.cancel()
    favoriteHUDTask?.cancel()
    controlsTask?.cancel()
    timelinePreviewTask?.cancel()
    subtitleLoadTask?.cancel()
    auxiliaryLoadTask?.cancel()
    pauseActivePlayer()
    vlcController.stop()
    RemotePlaybackCoordinator.shared.deactivate()
    PlayerOrientation.request(.portrait)
  }

  @ViewBuilder
  private var playerLayer: some View {
    if let model {
      if useVLC, model.selectedSource?.isOriginal == true, VLCAvailability.isAvailable {
        VLCPlayerView(controller: vlcController)
      } else {
        SystemPlayerView(
          player: model.player,
          presentationController: systemPresentationController,
          videoLayout: videoLayout
        )
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
        .onLongPressGesture(minimumDuration: 0.55, maximumDistance: 24) {
          toggleFavoriteFromLongPress()
        }
        .frame(width: proxy.size.width * 0.34)
      gestureSurface(isLeft: false, proxy: proxy)
    }
    .ignoresSafeArea()
    .highPriorityGesture(videoPinchGesture)
    .allowsHitTesting(!isLocked)
  }

  private var videoPinchGesture: some Gesture {
    MagnificationGesture()
      .onChanged { value in
        guard appState.playerGesturesEnabled, !isLocked else { return }
        if !isPinchInteracting {
          isPinchInteracting = true
          pinchStartScale = videoScale
          // A pinch is always a two-finger picture gesture. Clear any pending
          // one-finger brightness/volume baseline so the two gesture families
          // cannot keep updating each other during the same touch sequence.
          gestureStartBrightness = nil
          gestureStartVolume = nil
          isGestureInteracting = false
          controlsTask?.cancel()
        }
        let next = min(max(pinchStartScale * value, 0.75), 3.0)
        videoScale = next
        updateContinuousGestureHUD("画面  \(Int((next * 100).rounded()))%")
      }
      .onEnded { value in
        guard appState.playerGesturesEnabled, !isLocked else {
          isPinchInteracting = false
          return
        }
        videoScale = min(max(pinchStartScale * value, 0.75), 3.0)
        pinchStartScale = videoScale
        isPinchInteracting = false
        finishContinuousGestureHUD()
        scheduleControlsHide()
      }
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
            guard appState.playerGesturesEnabled, !isPinchInteracting else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            guard abs(dy) >= abs(dx) else { return }

            if !isGestureInteracting {
              isGestureInteracting = true
              controlsTask?.cancel()
              gestureStartBrightness = UIScreen.main.brightness
              gestureStartVolume = activeVolume
            }

            let normalizedDelta = -dy / availableHeight * 1.35
            if isLeft {
              let start = gestureStartBrightness ?? UIScreen.main.brightness
              let next = min(max(start + normalizedDelta, 0), 1)
              UIScreen.main.brightness = next
              updateContinuousGestureHUD("亮度  \(Int((next * 100).rounded()))%")
            } else {
              let start = CGFloat(gestureStartVolume ?? activeVolume)
              let next = min(max(start + normalizedDelta, 0), 1)
              setActiveVolume(Float(next))
              updateContinuousGestureHUD("音量  \(Int((next * 100).rounded()))%")
            }
          }
          .onEnded { value in
            guard appState.playerGesturesEnabled else { return }
            if isPinchInteracting {
              gestureStartBrightness = nil
              gestureStartVolume = nil
              isGestureInteracting = false
              return
            }
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
            if isGestureInteracting { finishContinuousGestureHUD() }
            isGestureInteracting = false
            scheduleControlsHide()
          }
      )
  }

  private func lockShield(proxy: GeometryProxy) -> some View {
    ZStack(alignment: .trailing) {
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
      .padding(.trailing, max(proxy.safeAreaInsets.trailing, 16))
    }
  }

  private func topOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height

    return HStack(spacing: landscape ? 10 : 8) {
      playerIconButton("xmark") {
        pauseActivePlayer()
        dismiss()
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(localMetadata?.displayTitle(fallback: currentItem.name) ?? currentItem.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .lineLimit(1)

        if playlist.count > 1 {
          Text("第 \(max(currentIndex + 1, 1)) / \(playlist.count) 个")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.52))
        }
      }
      .layoutPriority(1)

      Spacer(minLength: 6)

      if !useVLC {
        AirPlayRoutePickerButton { presented in
          isRoutePickerPresented = presented
          if presented {
            keepControlsDuringInteraction()
          } else {
            scheduleControlsHide()
          }
        }
        .frame(width: 38, height: 38)
        .background(.black.opacity(0.46), in: Circle())
        .clipShape(Circle())
        .accessibilityLabel("AirPlay")
      }

      if !useVLC, systemPresentationController.isPictureInPictureSupported {
        playerIconButton(
          systemPresentationController.isPictureInPictureActive ? "pip.exit" : "pip.enter"
        ) {
          keepControlsDuringInteraction()
          systemPresentationController.startPictureInPicture()
          scheduleControlsHide()
        }
      }

      playerIconButton("rectangle.landscape.rotate") {
        PlayerOrientation.toggle()
        keepControlsDuringInteraction()
        scheduleControlsHide()
      }
      .accessibilityLabel("切换横屏或竖屏")

      if landscape {
        playerIconButton("lock.fill") {
          showSettingsPanel = false
          showSpeedPanel = false
          showQueuePanel = false
          isLocked = true
          controlsVisible = false
          controlsTask?.cancel()
          showGestureHUD("控制已锁定")
        }
      }

      playerIconButton("ellipsis") {
        openSettingsPanel()
      }
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, landscape ? 18 : 12))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, landscape ? 18 : 12))
    .padding(
      .top,
      landscape
        ? max(proxy.safeAreaInsets.top + 20, 30)
        : max(proxy.safeAreaInsets.top + 22, 66)
    )
    .padding(.bottom, landscape ? 20 : 12)
    .background(
      LinearGradient(
        colors: [.black.opacity(landscape ? 0.44 : 0.58), .clear],
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

  private func speedOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height
    let panelWidth = landscape ? 286.0 : min(max(proxy.size.width * 0.62, 230), 290)

    return ZStack(alignment: .bottomLeading) {
      Color.black.opacity(0.001)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { closeSpeedPanel() }

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("播放速度")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
          Spacer()
          Text(formatRate(Double(playbackRate)))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white.opacity(0.58))
        }

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
          ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
            settingsChip(
              formatRate(rate),
              selected: abs(Double(playbackRate) - rate) < 0.001
            ) {
              applyPlaybackRate(Float(rate))
              closeSpeedPanel()
            }
          }
        }
      }
      .padding(14)
      .frame(width: panelWidth)
      .background(.black.opacity(0.88))
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(.white.opacity(0.10), lineWidth: 0.8)
      }
      .shadow(color: .black.opacity(0.34), radius: 20, y: 8)
      .padding(.leading, max(proxy.safeAreaInsets.leading, landscape ? 24 : 16))
      .padding(.bottom, max(proxy.safeAreaInsets.bottom, landscape ? 10 : 14) + 74)
    }
  }

  private func queueOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height
    let panelWidth = landscape ? min(380.0, proxy.size.width * 0.45) : max(proxy.size.width - 20, 300)
    let panelHeight = landscape ? min(proxy.size.height * 0.86, 520) : min(proxy.size.height * 0.68, 600)

    return ZStack(alignment: landscape ? .trailing : .bottom) {
      Color.black.opacity(0.30)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { closeQueuePanel() }

      VStack(spacing: 0) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("播放队列")
              .font(.headline.weight(.semibold))
              .foregroundStyle(.white)
            Text("同目录 · \(playlist.count) 个视频")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.54))
          }
          Spacer()
          Button { closeQueuePanel() } label: {
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

        ScrollViewReader { reader in
          ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 6) {
              ForEach(Array(playlist.enumerated()), id: \.element.id) { index, item in
                Button {
                  closeQueuePanel(scheduleHide: false)
                  switchTo(item)
                } label: {
                  HStack(spacing: 11) {
                    ZStack {
                      RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(item.id == currentItem.id ? CinevaTheme.accent.opacity(0.20) : .white.opacity(0.06))
                      Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(item.id == currentItem.id ? CinevaTheme.accent : .white.opacity(0.60))
                    }
                    .frame(width: 34, height: 30)

                    VStack(alignment: .leading, spacing: 3) {
                      Text(item.name)
                        .font(.subheadline.weight(item.id == currentItem.id ? .semibold : .regular))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                      HStack(spacing: 5) {
                        if !item.fileExtension.isEmpty { Text(item.fileExtension.uppercased()) }
                        Text(item.formattedSize)
                      }
                      .font(.caption2)
                      .foregroundStyle(.white.opacity(0.44))
                    }
                    Spacer(minLength: 6)
                    if item.id == currentItem.id {
                      Image(systemName: activeIsPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CinevaTheme.accent)
                    } else {
                      Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.34))
                    }
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(
                    item.id == currentItem.id ? .white.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                  )
                }
                .buttonStyle(.plain)
                .id(item.id)
              }
            }
            .padding(12)
          }
          .onAppear {
            reader.scrollTo(currentItem.id, anchor: .center)
          }
        }
      }
      .frame(width: panelWidth, height: panelHeight)
      .background(.black.opacity(0.90))
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: landscape ? 20 : 24, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: landscape ? 20 : 24, style: .continuous)
          .stroke(.white.opacity(0.10), lineWidth: 0.8)
      }
      .padding(.trailing, landscape ? max(proxy.safeAreaInsets.trailing, 18) : 10)
      .padding(.leading, landscape ? 10 : 10)
      .padding(.bottom, landscape ? 0 : max(proxy.safeAreaInsets.bottom, 10))
    }
  }

  private func playbackHUD(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height
    let resolution: String = {
      guard let size = model?.videoDisplaySize, size.width > 0, size.height > 0 else { return "读取中" }
      return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }()
    let networkText = activeNetworkMbps > 0.01 ? String(format: "%.1f Mbps", activeNetworkMbps) : "--"
    let bufferText = activeBufferedDuration > 0 ? "\(formatTime(activeBufferedDuration))" : "--"
    let transferredText = activeTransferredMegabytes > 0.1 ? String(format: "%.1f MB", activeTransferredMegabytes) : "--"
    let engine = useVLC ? "VLC" : "AVPlayer"
    let codec = useVLC ? currentItem.fileExtension.uppercased() : (model?.videoCodec ?? "读取中")
    let hdr = useVLC ? (currentItem.isDiscImage ? "ISO/IMG 原盘" : "VLC 原画") : (model?.hdrFormat ?? "SDR")
    let fps = (model?.nominalFrameRate ?? 0) > 0.1 ? String(format: "%.3g fps", model?.nominalFrameRate ?? 0) : nil

    return VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Image(systemName: "waveform.path.ecg")
        Text(engine)
        Text("·")
        Text(currentItem.fileExtension.uppercased())
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)

      Text([resolution, codec, hdr, fps].compactMap { $0 }.joined(separator: "  ·  "))
      Text("网络 \(networkText)  ·  缓冲 \(bufferText)  ·  已读取 \(transferredText)")
      if !useVLC, model?.hdrFormat == "Dolby Vision" {
        Text(AVPlayer.eligibleForHDRPlayback ? "Dolby Vision · 系统原生 HDR 管线" : "Dolby Vision · 当前显示设备不具备 HDR 播放资格")
          .foregroundStyle(.white.opacity(0.82))
      } else if currentItem.isDiscImage {
        Text("ISO/IMG：VLC 原盘主标题尝试，不启用光盘菜单")
          .foregroundStyle(.white.opacity(0.82))
      }
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.white.opacity(0.70))
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(.white.opacity(0.08), lineWidth: 0.6)
    }
    .frame(maxWidth: landscape ? 360 : 320, alignment: .leading)
    .position(
      x: max(proxy.safeAreaInsets.leading + (landscape ? 196 : 170), landscape ? 196 : 170),
      y: max(proxy.safeAreaInsets.top + (landscape ? 102 : 138), landscape ? 102 : 138)
    )
    .allowsHitTesting(false)
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

          if !activeChapters.isEmpty {
            settingsChapterSection()
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
            applyPlaybackRate(Float(rate))
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
              await model.select(source)
              activatePlaybackEngine(for: model)
              applyPlaybackRate(playbackRate, persist: false)
              applyAutomaticOrientation(for: model.videoDisplaySize)
              configureRemotePlayback()
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
      settingsRow(
        title: "关闭字幕",
        systemName: "captions.bubble",
        selected: model.selectedSubtitleOptionID == nil && selectedExternalSubtitleID == nil
      ) {
        model.selectSubtitle(nil)
        selectedExternalSubtitleID = nil
        externalSubtitleCues = []
        subtitleLoadTask?.cancel()
        keepControlsDuringInteraction()
      }

      ForEach(model.subtitleOptions) { option in
        settingsRow(
          title: option.title,
          systemName: "captions.bubble",
          selected: selectedExternalSubtitleID == nil && model.selectedSubtitleOptionID == option.id
        ) {
          selectedExternalSubtitleID = nil
          externalSubtitleCues = []
          subtitleLoadTask?.cancel()
          model.selectSubtitle(option.id)
          keepControlsDuringInteraction()
        }
      }

      ForEach(externalSubtitleTracks) { track in
        settingsRow(
          title: track.title,
          systemName: "captions.bubble.fill",
          selected: selectedExternalSubtitleID == track.id
        ) {
          model.selectSubtitle(nil)
          loadExternalSubtitle(track)
          keepControlsDuringInteraction()
        }
      }

      if model.subtitleOptions.isEmpty && externalSubtitleTracks.isEmpty {
        settingsUnavailableRow("当前视频没有发现字幕", systemName: "captions.bubble")
      }
    }
  }

  private func settingsChapterSection() -> some View {
    VStack(alignment: .leading, spacing: 10) {
      settingsSectionTitle("章节")
      VStack(spacing: 6) {
        ForEach(activeChapters) { chapter in
          let selected = activeCurrentTime >= chapter.start
            && (chapter.end <= chapter.start || activeCurrentTime < chapter.end)
          settingsRow(
            title: "\(formatTime(chapter.start))  \(chapter.title)",
            systemName: "bookmark",
            selected: selected
          ) {
            seekActive(to: chapter.start)
            keepControlsDuringInteraction()
          }
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

      settingsActionButton(showPlaybackHUD ? "关闭 HUD" : "播放 HUD", systemName: "waveform.path.ecg") {
        showPlaybackHUD.toggle()
        keepControlsDuringInteraction()
      }

      HStack(spacing: 8) {
        settingsActionButton("详情", systemName: "info.circle") {
          closeSettingsPanel(scheduleHide: false)
          showInfo = true
        }
        settingsActionButton(
          systemPresentationController.isPictureInPictureActive ? "退出小窗" : "小窗播放",
          systemName: systemPresentationController.isPictureInPictureActive ? "pip.exit" : "pip.enter",
          enabled: !useVLC && systemPresentationController.isPictureInPictureSupported
        ) {
          closeSettingsPanel(scheduleHide: false)
          systemPresentationController.startPictureInPicture()
        }
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

    return VStack(spacing: landscape ? 6 : 8) {
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
          // Portrait keeps only the timeline; the small spacer places it slightly lower
          // without crowding the home indicator.
          Color.clear
            .frame(height: 18)
            .allowsHitTesting(false)
        }
      }
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, landscape ? 24 : 16))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, landscape ? 24 : 16))
    .padding(.top, landscape ? 34 : 28)
    .padding(.bottom, max(proxy.safeAreaInsets.bottom, landscape ? 8 : 12) + 2)
    .background(
      LinearGradient(
        colors: [.clear, .black.opacity(landscape ? 0.58 : 0.70)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func portraitCenterTransport(model: PlayerModel) -> some View {
    Button {
      toggleActivePlayback()
      controlsVisible = true
      scheduleControlsHide()
    } label: {
      Image(systemName: activeIsPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: 62, height: 62)
        .background(.white, in: Circle())
        .shadow(color: .black.opacity(0.30), radius: 14, y: 5)
    }
    .buttonStyle(.plain)
    .highPriorityGesture(
      LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
        .onEnded { _ in toggleFavoriteFromLongPress() }
    )
  }

  private func portraitUtilityBar(model: PlayerModel) -> some View {
    HStack(spacing: 8) {
      utilityButton(title: formatRate(Double(playbackRate)), systemName: "speedometer") {
        openSpeedPanel()
      }

      Spacer(minLength: 12)

      if playlist.count > 1 {
        utilityIconButton("rectangle.stack.badge.play") {
          openQueuePanel()
        }
        .accessibilityLabel("播放队列")
      }
    }
  }

  private func landscapeCenterTransport(model: PlayerModel) -> some View {
    Button {
      toggleActivePlayback()
      controlsVisible = true
      scheduleControlsHide()
    } label: {
      Image(systemName: activeIsPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 27, weight: .bold))
        .foregroundStyle(.black)
        .frame(width: 68, height: 68)
        .background(.white, in: Circle())
        .shadow(color: .black.opacity(0.34), radius: 16, y: 6)
    }
    .buttonStyle(.plain)
    .highPriorityGesture(
      LongPressGesture(minimumDuration: 0.55, maximumDistance: 24)
        .onEnded { _ in toggleFavoriteFromLongPress() }
    )
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
        .background(.black.opacity(enabled ? 0.20 : 0.12), in: Circle())
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
        openSpeedPanel()
      }

      Spacer(minLength: 12)

      if playlist.count > 1 {
        utilityIconButton("rectangle.stack.badge.play") {
          openQueuePanel()
        }
        .accessibilityLabel("播放队列")
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
        let duration = max(activeDuration, 1)
        let current = min(max(isScrubbing ? scrubValue : activeCurrentTime, 0), duration)
        let buffered = min(max(activeBufferedUntil, 0), duration)
        let playedProgress = CGFloat(current / duration)
        let bufferedProgress = CGFloat(buffered / duration)
        let playedX = width * playedProgress
        let bufferedX = width * bufferedProgress

        ZStack(alignment: .leading) {
          Capsule()
            .fill(.white.opacity(0.20))
            .frame(height: 3)

          if !useVLC {
            Capsule()
              .fill(.white.opacity(0.32))
              .frame(width: bufferedX, height: 3)
          }

          Capsule()
            .fill(CinevaTheme.accent)
            .frame(width: playedX, height: 3)

          if appState.showChapterMarkers, activeDuration > 0 {
            ForEach(activeChapters) { chapter in
              let markerX = width * CGFloat(min(max(chapter.start / duration, 0), 1))
              Rectangle()
                .fill(.white.opacity(0.70))
                .frame(width: 1, height: 9)
                .offset(x: min(max(markerX, 0), width - 1))
            }
          }

          Circle()
            .fill(.white)
            .frame(width: isScrubbing ? 10 : 8, height: isScrubbing ? 10 : 8)
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .offset(x: min(max(playedX - (isScrubbing ? 5 : 4), 0), max(width - (isScrubbing ? 10 : 8), 0)))
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
          if isScrubbing,
            appState.timelinePreviewEnabled,
            !useVLC,
            let timelinePreviewImage
          {
            VStack(spacing: 5) {
              Image(uiImage: timelinePreviewImage)
                .resizable()
                .scaledToFill()
                .frame(width: 168, height: 94)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              Text(formatTime(scrubValue))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            }
            .padding(6)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .offset(y: -118)
            .allowsHitTesting(false)
            .transition(.opacity)
          }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              if !isScrubbing {
                isScrubbing = true
                controlsTask?.cancel()
              }
              let x = min(max(value.location.x, 0), width)
              scrubValue = Double(x / width) * duration
              requestTimelinePreview(at: scrubValue)
            }
            .onEnded { value in
              let x = min(max(value.location.x, 0), width)
              scrubValue = Double(x / width) * duration
              seekActive(to: scrubValue)
              isScrubbing = false
              timelinePreviewTask?.cancel()
              timelinePreviewImage = nil
              timelinePreviewBucket = -1
              scheduleControlsHide()
            }
        )
      }
      .frame(height: 28)

      HStack {
        Text(formatTime(isScrubbing ? scrubValue : activeCurrentTime))
        Spacer()
        if let chapter = currentChapter {
          Text(chapter.title)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.52))
        } else if !useVLC, activeBufferedUntil > activeCurrentTime + 1 {
          Text("已缓冲 \(formatTime(activeBufferedUntil))")
            .foregroundStyle(.white.opacity(0.46))
        }
        Spacer()
        Text(formatTime(activeDuration))
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

  @MainActor
  private func toggleFavoriteFromLongPress() {
    appState.libraryStore.toggleFavorite(currentItem)

    let feedback = UIImpactFeedbackGenerator(style: .medium)
    feedback.prepare()
    feedback.impactOccurred()

    favoriteHUDTask?.cancel()
    withAnimation(.spring(response: 0.24, dampingFraction: 0.68)) {
      showFavoriteHeart = true
    }
    favoriteHUDTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(620))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.20)) {
        showFavoriteHeart = false
      }
    }
  }

  private var autoHideSuspended: Bool {
    isScrubbing
      || isGestureInteracting
      || isControlsInteractionActive
      || showSettingsPanel
      || showSpeedPanel
      || showQueuePanel
      || showPlaybackHUD
      || showInfo
      || isRoutePickerPresented
  }

  private var chromeShouldBeVisible: Bool {
    controlsVisible || autoHideSuspended
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
    timelinePreviewTask?.cancel()
    subtitleLoadTask?.cancel()
    auxiliaryLoadTask?.cancel()
    timelinePreviewImage = nil
    timelinePreviewBucket = -1
    externalSubtitleTracks = []
    selectedExternalSubtitleID = nil
    externalSubtitleCues = []
    sidecarChapters = []

    let expectedItem = currentItem
    let expectedID = expectedItem.id

    if !didLoadPreferredRate {
      playbackRate = appState.preferredPlaybackRate
      didLoadPreferredRate = true
    }

    if model != nil {
      pauseActivePlayer()
      vlcController.stop()
    }

    let newModel = PlayerModel(
      item: expectedItem,
      api: appState.api,
      libraryStore: appState.libraryStore,
      defaultQuality: appState.defaultQuality,
      fastStartEnabled: appState.fastStartEnabled,
      networkAutoRecoveryEnabled: appState.networkAutoRecoveryEnabled
    )
    model = newModel
    newModel.setPlaybackRate(playbackRate)

    // The first frame has strict priority. Do not even START NFO/poster,
    // subtitle, chapter, or full-playlist requests until the playback engine has
    // received its URL and begun opening the media connection.
    await newModel.prepareAndPlay()
    guard !Task.isCancelled, currentItem.id == expectedID, model === newModel else {
      newModel.player.pause()
      return
    }

    activatePlaybackEngine(for: newModel)
    applyPlaybackRate(playbackRate, persist: false)
    applyAutomaticOrientation(for: newModel.videoDisplaySize)
    configureRemotePlayback()
    updateRemotePlaybackInfo()
    controlsVisible = true
    scheduleControlsHide()

    auxiliaryLoadTask = Task { @MainActor in
      // Give AVPlayer/VLC the network for a moment before sidecar discovery.
      if appState.fastStartEnabled {
        try? await Task.sleep(nanoseconds: 650_000_000)
      }
      guard !Task.isCancelled, currentItem.id == expectedID, model === newModel else { return }

      async let subtitleTracksTask: [ExternalSubtitleTrack] =
        (try? await appState.api.externalSubtitleTracks(for: expectedItem)) ?? []
      async let sidecarChapterTask = appState.api.sidecarChapters(for: expectedItem)

      let tracks = await subtitleTracksTask
      guard !Task.isCancelled, currentItem.id == expectedID, model === newModel else { return }
      externalSubtitleTracks = tracks
      autoSelectExternalSubtitleIfNeeded()

      sidecarChapters = await sidecarChapterTask
      guard !Task.isCancelled, currentItem.id == expectedID, model === newModel else { return }

      // Poster/NFO can be much larger than chapter/subtitle discovery. Load it
      // after playback has had an additional head start so artwork never wins a
      // bandwidth race against the first seconds of the movie.
      if appState.fastStartEnabled {
        try? await Task.sleep(nanoseconds: 700_000_000)
      }
      guard !Task.isCancelled, currentItem.id == expectedID, model === newModel else { return }

      localMetadata = await appState.api.localMetadata(for: expectedItem)
      guard !Task.isCancelled, currentItem.id == expectedID, model === newModel else { return }
      configureRemotePlayback()

      await ensureCompletePlaylist(for: expectedItem)
    }
  }

  @MainActor
  private func applyAutomaticOrientation(for size: CGSize?) {
    // VLC fallback does not currently expose a reliable natural video size here.
    // Do not force those videos back to portrait; preserve the user's/device's
    // current orientation and keep the manual orientation button available.
    guard !useVLC else { return }
    guard let size, size.width > 0, size.height > 0 else { return }
    let ratio = size.width / max(size.height, 1)
    PlayerOrientation.request(ratio > 1.12 ? .landscape : .portrait)
  }

  @MainActor
  private func activatePlaybackEngine(for playerModel: PlayerModel) {
    guard let source = playerModel.selectedSource else {
      useVLC = false
      return
    }

    if playerModel.requiresVLC, source.isOriginal, VLCAvailability.isAvailable {
      useVLC = true
      vlcController.configure(
        source: source,
        item: currentItem,
        libraryStore: appState.libraryStore,
        playbackRate: playbackRate,
        fastStartEnabled: appState.fastStartEnabled
      )
    } else {
      if useVLC {
        vlcController.stop(saveProgress: false)
      }
      useVLC = false
      playerModel.setPlaybackRate(playbackRate)
    }
  }

  @MainActor
  private func ensureCompletePlaylist(for expectedItem: CloudItem) async {
    let parent = expectedItem.parentID
    guard !parent.isEmpty, loadedPlaylistParentID != parent else { return }

    do {
      let all = try await appState.api.listFolder(id: parent)
      guard !Task.isCancelled, currentItem.id == expectedItem.id else { return }
      var videos = all.filter { !$0.isDirectory && $0.isVideo }
      if !videos.contains(where: { $0.id == expectedItem.id }) {
        videos.append(expectedItem)
      }
      videos.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      playlist = videos
      loadedPlaylistParentID = parent
    } catch {
      guard !Task.isCancelled, currentItem.id == expectedItem.id else { return }
      // Keep the playlist supplied by the source screen. Queue expansion is an
      // enhancement and must never make playback fail.
      if !playlist.contains(where: { $0.id == expectedItem.id }) {
        playlist.append(expectedItem)
      }
    }
  }

  @MainActor
  private func withActiveEngine(_ action: (any CinevaPlaybackEngine) -> Void) {
    if useVLC {
      action(vlcController)
    } else if let model {
      action(model)
    }
  }

  @MainActor
  private func applyPlaybackRate(_ rate: Float, persist: Bool = true) {
    let safe = min(max(rate, 0.5), 2.0)
    playbackRate = safe
    if persist { appState.preferredPlaybackRate = safe }
    withActiveEngine { $0.engineSetPlaybackRate(safe) }
    updateRemotePlaybackInfo()
  }

  @MainActor
  private func toggleActivePlayback() {
    withActiveEngine { $0.engineTogglePlayback() }
    updateRemotePlaybackInfo()
  }

  @MainActor
  private func pauseActivePlayer() {
    withActiveEngine { $0.enginePause() }
    updateRemotePlaybackInfo()
  }

  @MainActor
  private func resumeActivePlayer() {
    withActiveEngine { $0.engineResume() }
    updateRemotePlaybackInfo()
  }

  @MainActor
  private func replayActivePlayer() {
    if useVLC {
      vlcController.replay()
    } else if let model {
      Task { @MainActor in
        await model.replay()
      }
    }
  }

  @MainActor
  private func seekActive(to seconds: Double) {
    withActiveEngine { $0.engineSeek(to: seconds) }
    updateRemotePlaybackInfo()
  }

  @MainActor
  private func setActiveVolume(_ volume: Float) {
    let safe = min(max(volume, 0), 1)
    withActiveEngine { $0.engineSetVolume(safe) }
  }

  private var activeCurrentTime: Double {
    useVLC ? vlcController.currentTime : (model?.currentTime ?? 0)
  }

  private var activeDuration: Double {
    if useVLC, vlcController.duration > 0 { return vlcController.duration }
    if let duration = model?.duration, duration > 0 { return duration }
    return appState.libraryStore.knownDuration(for: currentItem)
  }

  private var activeBufferedUntil: Double {
    useVLC ? activeCurrentTime : (model?.bufferedUntil ?? 0)
  }

  private var activeBufferedDuration: Double {
    useVLC ? 0 : (model?.bufferedDuration ?? 0)
  }

  private var activeIsPlaying: Bool {
    useVLC ? vlcController.isPlaying : (model?.isPlaying ?? false)
  }

  private var activeIsBuffering: Bool {
    useVLC ? vlcController.isBuffering : (model?.isBuffering ?? false)
  }

  private var activeDidReachEnd: Bool {
    useVLC ? vlcController.didReachEnd : (model?.didReachEnd ?? false)
  }

  private var activeNetworkMbps: Double {
    useVLC ? vlcController.networkMbps : (model?.networkMbps ?? 0)
  }

  private var activeTransferredMegabytes: Double {
    useVLC ? vlcController.transferredMegabytes : (model?.transferredMegabytes ?? 0)
  }

  private var activeVolume: Float {
    useVLC ? vlcController.volume : (model?.player.volume ?? 1)
  }

  private var activeChapters: [PlayerChapter] {
    if let embedded = model?.chapters, !embedded.isEmpty { return embedded }
    return sidecarChapters
  }

  private var currentChapter: PlayerChapter? {
    let chapters = activeChapters
    guard !chapters.isEmpty else { return nil }
    for (index, chapter) in chapters.enumerated() {
      let nextStart = index + 1 < chapters.count ? chapters[index + 1].start : activeDuration
      let end = chapter.end > chapter.start ? chapter.end : nextStart
      if activeCurrentTime >= chapter.start && (end <= chapter.start || activeCurrentTime < end) {
        return chapter
      }
    }
    return nil
  }

  private var activeExternalSubtitleText: String? {
    guard selectedExternalSubtitleID != nil, !externalSubtitleCues.isEmpty else { return nil }
    let time = activeCurrentTime - appState.subtitleTimeOffset
    guard time >= 0 else { return nil }

    var low = 0
    var high = externalSubtitleCues.count - 1
    var candidate = -1
    while low <= high {
      let mid = (low + high) / 2
      if externalSubtitleCues[mid].start <= time {
        candidate = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    guard candidate >= 0 else { return nil }

    // Overlapping subtitle events are common in ASS files. Walk backwards a few
    // cues so a still-active event isn't missed by the binary-search candidate.
    for index in stride(from: candidate, through: max(candidate - 4, 0), by: -1) {
      let cue = externalSubtitleCues[index]
      if time >= cue.start, time <= cue.end { return cue.text }
    }
    return nil
  }

  private func externalSubtitleOverlay(text: String, proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height
    let bottomPadding: CGFloat = landscape
      ? (chromeShouldBeVisible ? 88 : 38)
      : (chromeShouldBeVisible ? 128 : 58)

    return VStack {
      Spacer()
      Text(text)
        .font(.system(size: 21 * appState.subtitleFontScale, weight: .semibold))
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: proxy.size.width * (landscape ? 0.72 : 0.88))
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
        .padding(.bottom, bottomPadding)
    }
    .frame(width: proxy.size.width, height: proxy.size.height)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func skipSegmentOverlay(proxy: GeometryProxy) -> some View {
    let landscape = proxy.size.width > proxy.size.height
    VStack {
      Spacer()
      HStack {
        Spacer()
        if shouldShowIntroSkip {
          skipSegmentButton("跳过片头", systemName: "forward.end.fill") {
            seekActive(to: resolvedIntroTarget)
          }
        } else if shouldShowOutroSkip {
          skipSegmentButton("跳过片尾", systemName: "forward.end.fill") {
            if nextItem != nil {
              playNextIfAvailable()
            } else {
              seekActive(to: max(activeDuration - 0.5, 0))
            }
          }
        }
      }
      .padding(.trailing, max(proxy.safeAreaInsets.trailing, landscape ? 24 : 16))
      .padding(.bottom, landscape ? 74 : 116)
    }
  }

  private func skipSegmentButton(
    _ title: String,
    systemName: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Text(title)
        Image(systemName: systemName)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 15)
      .frame(height: 40)
      .background(.black.opacity(0.68), in: Capsule())
      .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 0.7) }
    }
    .buttonStyle(.plain)
  }

  private var resolvedIntroTarget: Double {
    if let chapter = activeChapters.first(where: { chapterMatches($0, keywords: ["片头", "intro", "opening", " op ", "op"]) }),
      chapter.end > chapter.start
    {
      return min(chapter.end, activeDuration)
    }
    return min(Double(appState.introSkipSeconds), activeDuration)
  }

  private var shouldShowIntroSkip: Bool {
    guard appState.skipIntroEnabled, activeDuration > 0 else { return false }
    let target = resolvedIntroTarget
    return target > 5 && activeCurrentTime >= 2 && activeCurrentTime < target - 1
  }

  private var shouldShowOutroSkip: Bool {
    guard appState.skipOutroEnabled, activeDuration > 0 else { return false }
    if let outro = activeChapters.first(where: { chapterMatches($0, keywords: ["片尾", "outro", "ending", "credits", "credit", "ed"]) }) {
      return activeCurrentTime >= outro.start && activeCurrentTime < activeDuration - 1
    }
    let remaining = activeDuration - activeCurrentTime
    return remaining > 2 && remaining <= Double(appState.outroPromptSeconds)
  }

  private func chapterMatches(_ chapter: PlayerChapter, keywords: [String]) -> Bool {
    let value = " \(chapter.title.lowercased()) "
    return keywords.contains { value.contains($0) }
  }

  @MainActor
  private func requestTimelinePreview(at seconds: Double) {
    guard appState.timelinePreviewEnabled, !useVLC, let model else { return }
    let bucket = max(0, Int((seconds / 5).rounded(.down)) * 5)
    guard bucket != timelinePreviewBucket else { return }
    timelinePreviewBucket = bucket
    timelinePreviewImage = nil
    timelinePreviewTask?.cancel()
    let expectedID = currentItem.id

    timelinePreviewTask = Task { @MainActor in
      let image = await model.timelinePreview(at: seconds)
      guard !Task.isCancelled,
        currentItem.id == expectedID,
        timelinePreviewBucket == bucket
      else { return }
      timelinePreviewImage = image
    }
  }

  @MainActor
  private func loadExternalSubtitle(_ track: ExternalSubtitleTrack) {
    selectedExternalSubtitleID = track.id
    externalSubtitleCues = []
    subtitleLoadTask?.cancel()
    let expectedID = currentItem.id

    subtitleLoadTask = Task { @MainActor in
      do {
        let cues = try await appState.api.subtitleCues(for: track)
        guard !Task.isCancelled,
          currentItem.id == expectedID,
          selectedExternalSubtitleID == track.id
        else { return }
        externalSubtitleCues = cues.sorted { $0.start < $1.start }
        if cues.isEmpty { showGestureHUD("字幕文件没有可识别时间轴") }
      } catch {
        guard !Task.isCancelled, currentItem.id == expectedID else { return }
        selectedExternalSubtitleID = nil
        externalSubtitleCues = []
        showGestureHUD("字幕读取失败")
      }
    }
  }

  @MainActor
  private func autoSelectExternalSubtitleIfNeeded() {
    guard appState.autoLoadExternalSubtitles, !externalSubtitleTracks.isEmpty else { return }
    let preferredTokens = ["zh", "chs", "cht", "chi", "cn", "中文", "简体", "繁体"]
    let preferred = externalSubtitleTracks.first { track in
      let normalized = track.title.lowercased()
      return preferredTokens.contains { token in normalized == token || normalized.contains(".\(token)") || normalized.contains("-\(token)") || normalized.contains("_\(token)") || normalized.contains(token) }
    }
    if let track = preferred ?? (externalSubtitleTracks.count == 1 ? externalSubtitleTracks.first : nil) {
      model?.selectSubtitle(nil)
      loadExternalSubtitle(track)
    }
  }

  @MainActor
  private func configureRemotePlayback() {
    RemotePlaybackCoordinator.shared.activate(
      skipSeconds: appState.doubleTapSeekSeconds,
      onPlay: { resumeActivePlayer() },
      onPause: { pauseActivePlayer() },
      onToggle: { toggleActivePlayback() },
      onSeek: { seconds in seekActive(to: seconds) },
      onSkipBackward: { seekBy(-Double(appState.doubleTapSeekSeconds)) },
      onSkipForward: { seekBy(Double(appState.doubleTapSeekSeconds)) },
      onPrevious: previousItem == nil ? nil : { playPreviousIfAvailable() },
      onNext: nextItem == nil ? nil : { playNextIfAvailable() }
    )
    RemotePlaybackCoordinator.shared.setMetadata(
      title: localMetadata?.displayTitle(fallback: currentItem.name) ?? currentItem.name,
      subtitle: currentItem.parentID.split(separator: "/").last.map(String.init) ?? "Cineva",
      artworkData: localMetadata?.posterData
    )
  }

  @MainActor
  private func updateRemotePlaybackInfo() {
    RemotePlaybackCoordinator.shared.updatePlayback(
      elapsed: activeCurrentTime,
      duration: activeDuration,
      rate: activeIsPlaying ? playbackRate : 0,
      isPlaying: activeIsPlaying
    )
  }

  @MainActor
  private func handleInteractiveOverlayChange(_ presented: Bool) {
    if presented {
      controlsTask?.cancel()
      controlsVisible = true
    } else {
      scheduleControlsHide()
    }
  }

  @MainActor
  private func showControls(animated: Bool) {
    if animated {
      withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
    } else {
      controlsVisible = true
    }
  }

  @MainActor
  private func openQueuePanel() {
    controlsTask?.cancel()
    controlsVisible = true
    showSettingsPanel = false
    showSpeedPanel = false
    withAnimation(.easeOut(duration: 0.18)) {
      showQueuePanel = true
    }
  }

  @MainActor
  private func closeQueuePanel(scheduleHide: Bool = true) {
    withAnimation(.easeIn(duration: 0.16)) {
      showQueuePanel = false
    }
    if scheduleHide { scheduleControlsHide() }
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
    showSpeedPanel = false
    showQueuePanel = false
    pauseActivePlayer()
    vlcController.stop()
    model = nil
    useVLC = false
    localMetadata = nil
    videoScale = 1.0
    pinchStartScale = 1.0
    isPinchInteracting = false
    if item.parentID != loadedPlaylistParentID {
      loadedPlaylistParentID = nil
    }
    currentItem = item
    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
  }

  @MainActor
  private func seekBy(_ seconds: Double) {
    guard model != nil else { return }
    if useVLC {
      vlcController.seekBy(seconds)
    } else {
      model?.seekBy(seconds)
    }
    updateRemotePlaybackInfo()
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
  private func openSpeedPanel() {
    controlsTask?.cancel()
    controlsVisible = true
    showSettingsPanel = false
    withAnimation(.easeOut(duration: 0.16)) {
      showSpeedPanel = true
    }
  }

  @MainActor
  private func closeSpeedPanel(scheduleHide: Bool = true) {
    withAnimation(.easeIn(duration: 0.14)) {
      showSpeedPanel = false
    }
    if scheduleHide {
      scheduleControlsHide()
    }
  }

  @MainActor
  private func openSettingsPanel() {
    controlsTask?.cancel()
    controlsVisible = true
    showSpeedPanel = false
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
    guard activeIsPlaying, !isLocked, !autoHideSuspended else { return }

    controlsTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2.0))
      guard !Task.isCancelled,
        activeIsPlaying,
        !isLocked,
        !autoHideSuspended
      else { return }

      withAnimation(.easeInOut(duration: 0.26)) {
        controlsVisible = false
      }
    }
  }

  @MainActor
  private func updateContinuousGestureHUD(_ message: String) {
    hudTask?.cancel()
    if gestureHUD == nil {
      withAnimation(.easeOut(duration: 0.10)) { gestureHUD = message }
    } else {
      // During a live drag/pinch, update the monospaced number directly. Starting
      // a new transition animation and hide task for every touch sample made the
      // brightness/volume HUD visibly lag behind the finger.
      gestureHUD = message
    }
  }

  @MainActor
  private func finishContinuousGestureHUD() {
    hudTask?.cancel()
    hudTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(650))
      guard !Task.isCancelled else { return }
      withAnimation(.easeIn(duration: 0.14)) { gestureHUD = nil }
    }
  }

  @MainActor
  private func showGestureHUD(_ message: String) {
    hudTask?.cancel()
    if gestureHUD == nil {
      withAnimation(.easeOut(duration: 0.12)) { gestureHUD = message }
    } else {
      gestureHUD = message
    }
    hudTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(950))
      guard !Task.isCancelled else { return }
      withAnimation(.easeIn(duration: 0.16)) { gestureHUD = nil }
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

}

private struct PlayerInfoSheet: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let model: PlayerModel?
  let videoLayout: PlayerVideoLayout
  let playbackRate: Float
  let playlistCount: Int
  let localMetadata: LocalMediaMetadata?
  let networkMbps: Double
  let bufferedDuration: Double
  let playbackEngine: String

  var body: some View {
    NavigationStack {
      List {
        if let localMetadata, localMetadata.hasUsefulMetadata {
          Section("本地元数据") {
            if let title = localMetadata.title { LabeledContent("标题", value: title) }
            if let year = localMetadata.year { LabeledContent("年份", value: year) }
            if let genre = localMetadata.genre { LabeledContent("类型", value: genre) }
            if let studio = localMetadata.studio { LabeledContent("制片", value: studio) }
            if let showTitle = localMetadata.showTitle { LabeledContent("剧集", value: showTitle) }
            if let season = localMetadata.season, let episode = localMetadata.episode {
              LabeledContent("集数", value: String(format: "S%02dE%02d", season, episode))
            }
            if let director = localMetadata.director { LabeledContent("导演", value: director) }
            if let rating = localMetadata.rating { LabeledContent("评分", value: rating) }
            if let overview = localMetadata.overview {
              VStack(alignment: .leading, spacing: 6) {
                Text("简介").font(.caption).foregroundStyle(.secondary)
                Text(overview).font(.subheadline)
              }
            }
          }
        }

        Section("视频") {
          LabeledContent("名称", value: item.name)
          LabeledContent("大小", value: item.formattedSize)
          if !item.fileExtension.isEmpty {
            LabeledContent("格式", value: item.fileExtension.uppercased())
          }
          if let size = model?.videoDisplaySize, size.width > 0, size.height > 0 {
            LabeledContent("分辨率", value: "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))")
          }
          if let codec = model?.videoCodec, !codec.isEmpty {
            LabeledContent("视频编码", value: codec)
          }
          if let hdr = model?.hdrFormat, !hdr.isEmpty {
            LabeledContent("HDR", value: hdr)
          }
          if let fps = model?.nominalFrameRate, fps > 0.1 {
            LabeledContent("帧率", value: String(format: "%.3g fps", fps))
          }
          if item.isDiscImage {
            LabeledContent("原盘模式", value: "ISO/IMG 主标题尝试")
          }
        }

        Section("播放") {
          LabeledContent("播放内核", value: playbackEngine)
          LabeledContent("当前清晰度", value: model?.selectedSource?.title ?? "原画")
          LabeledContent("画面模式", value: videoLayout.title)
          LabeledContent("播放速度", value: playbackRate == 1 ? "1x" : String(format: "%gx", playbackRate))
          LabeledContent("同目录队列", value: "\(playlistCount) 个视频")
          LabeledContent("音轨", value: "\(model?.audioOptions.count ?? 0) 个可选")
          LabeledContent("字幕", value: "\(model?.subtitleOptions.count ?? 0) 个可选")
          LabeledContent("画中画", value: playbackEngine == "AVPlayer" ? "支持" : "当前内核不支持")
          if model?.hdrFormat == "Dolby Vision" {
            LabeledContent(
              "Dolby Vision",
              value: AVPlayer.eligibleForHDRPlayback ? "系统原生 HDR 管线" : "当前显示设备不具备 HDR 播放资格"
            )
          }
        }

        Section("网络") {
          LabeledContent(
            "实时速度",
            value: networkMbps > 0.01 ? String(format: "%.1f Mbps", networkMbps) : "--"
          )
          LabeledContent(
            "已缓冲",
            value: bufferedDuration > 0 ? formatTime(bufferedDuration) : "--"
          )
        }

        Section("手势") {
          LabeledContent("双击快进/快退", value: "\(appState.doubleTapSeekSeconds) 秒")
          LabeledContent("左右滑动", value: "快进 / 快退")
          LabeledContent("画面中间长按", value: "收藏 / 取消收藏")
          LabeledContent("左侧上下滑", value: "亮度")
          LabeledContent("右侧上下滑", value: "播放音量")
        }
      }
      .navigationTitle("播放详情")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%02d:%02d", minutes, secs)
  }
}


@MainActor
private final class RemotePlaybackCoordinator {
  static let shared = RemotePlaybackCoordinator()

  private let commandCenter = MPRemoteCommandCenter.shared()
  private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
  private var commandTokens: [Any] = []

  private var onPlay: (() -> Void)?
  private var onPause: (() -> Void)?
  private var onToggle: (() -> Void)?
  private var onSeek: ((Double) -> Void)?
  private var onSkipBackward: (() -> Void)?
  private var onSkipForward: (() -> Void)?
  private var onPrevious: (() -> Void)?
  private var onNext: (() -> Void)?

  private init() {
    commandTokens.append(commandCenter.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onPlay?() }
      return .success
    })
    commandTokens.append(commandCenter.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onPause?() }
      return .success
    })
    commandTokens.append(commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onToggle?() }
      return .success
    })
    commandTokens.append(commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onSkipBackward?() }
      return .success
    })
    commandTokens.append(commandCenter.skipForwardCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onSkipForward?() }
      return .success
    })
    commandTokens.append(commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onPrevious?() }
      return .success
    })
    commandTokens.append(commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onNext?() }
      return .success
    })
    commandTokens.append(commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      let position = event.positionTime
      Task { @MainActor in self?.onSeek?(position) }
      return .success
    })

    setCommandsEnabled(false)
  }

  func activate(
    skipSeconds: Int,
    onPlay: @escaping () -> Void,
    onPause: @escaping () -> Void,
    onToggle: @escaping () -> Void,
    onSeek: @escaping (Double) -> Void,
    onSkipBackward: @escaping () -> Void,
    onSkipForward: @escaping () -> Void,
    onPrevious: (() -> Void)?,
    onNext: (() -> Void)?
  ) {
    self.onPlay = onPlay
    self.onPause = onPause
    self.onToggle = onToggle
    self.onSeek = onSeek
    self.onSkipBackward = onSkipBackward
    self.onSkipForward = onSkipForward
    self.onPrevious = onPrevious
    self.onNext = onNext

    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.skipBackwardCommand.isEnabled = true
    commandCenter.skipForwardCommand.isEnabled = true
    commandCenter.previousTrackCommand.isEnabled = onPrevious != nil
    commandCenter.nextTrackCommand.isEnabled = onNext != nil
    commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipSeconds)]
    commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipSeconds)]
  }

  func setMetadata(title: String, subtitle: String, artworkData: Data?) {
    var info = nowPlayingCenter.nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyTitle] = title
    info[MPMediaItemPropertyAlbumTitle] = subtitle
    info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue)

    if let artworkData, let image = UIImage(data: artworkData) {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    } else {
      info.removeValue(forKey: MPMediaItemPropertyArtwork)
    }
    nowPlayingCenter.nowPlayingInfo = info
  }

  func updatePlayback(elapsed: Double, duration: Double, rate: Float, isPlaying: Bool) {
    var info = nowPlayingCenter.nowPlayingInfo ?? [:]
    if elapsed.isFinite {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(elapsed, 0)
    }
    if duration.isFinite, duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = rate
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = rate > 0 ? rate : 1.0
    nowPlayingCenter.nowPlayingInfo = info
    nowPlayingCenter.playbackState = isPlaying ? .playing : .paused
  }

  func deactivate() {
    onPlay = nil
    onPause = nil
    onToggle = nil
    onSeek = nil
    onSkipBackward = nil
    onSkipForward = nil
    onPrevious = nil
    onNext = nil
    setCommandsEnabled(false)
    nowPlayingCenter.nowPlayingInfo = nil
    nowPlayingCenter.playbackState = .stopped
  }

  private func setCommandsEnabled(_ enabled: Bool) {
    commandCenter.playCommand.isEnabled = enabled
    commandCenter.pauseCommand.isEnabled = enabled
    commandCenter.togglePlayPauseCommand.isEnabled = enabled
    commandCenter.changePlaybackPositionCommand.isEnabled = enabled
    commandCenter.skipBackwardCommand.isEnabled = enabled
    commandCenter.skipForwardCommand.isEnabled = enabled
    commandCenter.previousTrackCommand.isEnabled = enabled
    commandCenter.nextTrackCommand.isEnabled = enabled
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
