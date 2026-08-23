import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

private enum PlayerDragIntent {
  case undecided
  case zoomPan
  case portraitDismiss
  case landscapeBrightness
  case landscapeVolume
  case landscapeSeek
  case ignored
}

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
  @State private var gestureHUDSystemName = "sparkles"
  @State private var playbackFeedback: PlayerPlaybackFeedback?
  @State private var showFavoriteHeart = false
  @State private var favoriteHUDIsRemoval = false
  @State private var lastFavoriteToggleUptime: TimeInterval = 0
  @State private var hudTask: Task<Void, Never>?
  @State private var playbackFeedbackTask: Task<Void, Never>?
  @State private var favoriteHUDTask: Task<Void, Never>?
  @State private var controlsTask: Task<Void, Never>?
  @State private var scrubValue: Double = 0
  @State private var isScrubbing = false
  @State private var scrubWasPlaying = false
  @State private var isGestureInteracting = false
  @State private var isControlsInteractionActive = false
  @State private var gestureStartBrightness: CGFloat?
  @State private var gestureStartVolume: Float?
  @State private var volumeBeforeMute: Float = 1.0
  @State private var isPlayerMuted = false
  @State private var videoScale: CGFloat = 1.0
  @State private var pinchStartScale: CGFloat = 1.0
  @State private var pinchStartOffset: CGSize = .zero
  @State private var videoOffset: CGSize = .zero
  @State private var panStartOffset: CGSize = .zero
  @State private var isPinchInteracting = false
  @State private var dismissDragOffset: CGSize = .zero
  @State private var isDismissDragging = false
  @State private var isDismissSettling = false
  @State private var dismissControlsWereVisible = false
  @State private var dismissRestoreTask: Task<Void, Never>?
  @State private var dragIntent: PlayerDragIntent = .undecided
  @State private var singleFingerGestureSuppressedUntil: TimeInterval = 0
  @State private var externalSubtitleTracks: [ExternalSubtitleTrack] = []
  @State private var selectedExternalSubtitleID: String?
  @State private var externalSubtitleCues: [SubtitleCue] = []
  @State private var sidecarChapters: [PlayerChapter] = []
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
      // The player is presented with fullScreenCover. Keeping the presentation
      // background transparent lets the existing library remain alive and
      // visible underneath during the Photos-style interactive dismiss.
      .presentationBackground(.clear)
      // This screen supplies its own bidirectional direct-manipulation gesture.
      // Prevent the modal recognizer from stealing the same finger stream; the
      // committed dismissal still uses the existing card-linked zoom transition.
      .interactiveDismissDisabled()
  }

  private var playerBaseView: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black
          .opacity(interactiveDismissBackdropOpacity)
          .ignoresSafeArea()

        mediaPresentation(proxy: proxy)

        interactionLayer(proxy: proxy)

        if !isLocked, appState.isAppUnlocked, !isDismissMotionActive {
          skipSegmentOverlay(proxy: proxy)
            .zIndex(9)
        }

        if isLocked {
          lockShield(proxy: proxy)
        } else {
          playerChrome(proxy: proxy)
            .simultaneousGesture(controlsInteractionGesture)
            .opacity(chromeShouldBeVisible ? interactiveDismissChromeOpacity : 0)
            .scaleEffect(chromeShouldBeVisible ? 1 : 0.982)
            .animation(
              chromeShouldBeVisible
                ? .spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.08)
                : .easeOut(duration: 0.28),
              value: chromeShouldBeVisible
            )
            .allowsHitTesting(chromeShouldBeVisible && !isDismissMotionActive && !showSettingsPanel && !showSpeedPanel && !showQueuePanel)
            .accessibilityHidden(!chromeShouldBeVisible || isDismissMotionActive)
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

        if (activeIsBuffering || activeIsScrubLoading), !isDismissMotionActive {
          ProgressView()
            .controlSize(activeIsScrubLoading ? .regular : .large)
            .tint(.white)
            .padding(activeIsScrubLoading ? 12 : 16)
            .background(.black.opacity(activeIsScrubLoading ? 0.30 : 0.38), in: Circle())
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .allowsHitTesting(false)
        }

        if let playbackFeedback {
          PlayerPlaybackFeedbackView(feedback: playbackFeedback)
            .transition(.scale(scale: 0.84).combined(with: .opacity))
            .allowsHitTesting(false)
            .zIndex(35)
        }

        if let gestureHUD {
          PlayerGestureFeedbackView(systemName: gestureHUDSystemName, message: gestureHUD)
            .transition(.scale(scale: 0.90).combined(with: .opacity))
            .allowsHitTesting(false)
        }

        if showFavoriteHeart {
          VStack(spacing: 9) {
            Image(systemName: favoriteHUDIsRemoval ? "heart.slash" : "heart.fill")
              .font(.system(size: 48, weight: .semibold))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.red)
            Text(favoriteHUDIsRemoval ? "已取消收藏" : "已收藏")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
          }
            .frame(width: 142, height: 126)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
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
      .animation(.easeInOut(duration: 0.18), value: showPlaybackHUD)
    }
    .background(Color.clear)
    .ignoresSafeArea()
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
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
    playbackFeedbackTask?.cancel()
    favoriteHUDTask?.cancel()
    controlsTask?.cancel()
    subtitleLoadTask?.cancel()
    auxiliaryLoadTask?.cancel()
    dismissRestoreTask?.cancel()
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

  private func mediaPresentation(proxy: GeometryProxy) -> some View {
    PlayerMediaRenderingSurface(
      viewport: proxy.size,
      videoScale: videoScale,
      videoOffset: videoOffset,
      dismissScale: interactiveDismissMediaScale,
      dismissOffset: dismissDragOffset,
      dismissCornerRadius: interactiveDismissCornerRadius,
      dismissProgress: interactiveDismissProgress
    ) {
      playerLayer
    } overlay: {
      if let subtitleText = activeExternalSubtitleText {
        externalSubtitleOverlay(text: subtitleText, proxy: proxy)
          .zIndex(8)
      }
    }
  }

  private var isDismissMotionActive: Bool {
    isDismissDragging || isDismissSettling
  }

  private var interactiveDismissProgress: CGFloat {
    let verticalTravel = abs(dismissDragOffset.height)
    // One normalized, vertical progress value drives scale, corner radius,
    // backdrop and chrome. Horizontal finger drift no longer makes the player
    // unexpectedly shrink or reveal the library underneath.
    return CGFloat(1.0 - exp(-Double(verticalTravel) / 235.0))
  }

  private var interactiveDismissMediaScale: CGFloat {
    // Photos-like movement stays visually grounded: the media follows the
    // finger almost 1:1 and only shrinks subtly as the library is revealed.
    1.0 - interactiveDismissProgress * 0.10
  }

  private var interactiveDismissCornerRadius: CGFloat {
    interactiveDismissProgress * 26.0
  }

  private var interactiveDismissBackdropOpacity: Double {
    // Derive directly from displacement even during the spring-back animation.
    // This prevents the black backdrop from snapping back before the video does.
    max(0.08, 1.0 - Double(interactiveDismissProgress) * 0.92)
  }

  private var interactiveDismissChromeOpacity: Double {
    max(0, 1.0 - Double(interactiveDismissProgress) * 2.35)
  }

  private func interactionLayer(proxy: GeometryProxy) -> some View {
    HStack(spacing: 0) {
      gestureSurface(isLeft: true, proxy: proxy)
      Color.clear
        .contentShape(Rectangle())
        .gesture(mediaTapGesture {
          toggleActivePlayback(userInitiated: true)
          scheduleControlsHide()
        })
        .simultaneousGesture(
          LongPressGesture(minimumDuration: 0.48, maximumDistance: 24)
            .onEnded { _ in toggleFavoriteFromLongPress() }
        )
        .frame(width: proxy.size.width * 0.34)
      gestureSurface(isLeft: false, proxy: proxy)
    }
    .ignoresSafeArea()
    .highPriorityGesture(videoPinchGesture(proxy: proxy))
    .simultaneousGesture(videoDragGesture(proxy: proxy))
    .allowsHitTesting(!isLocked)
  }

  private func videoPinchGesture(proxy: GeometryProxy) -> some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.005)
      .onChanged { value in
        guard appState.playerGesturesEnabled, !isLocked else { return }
        if !isPinchInteracting {
          isPinchInteracting = true
          dragIntent = .undecided
          pinchStartScale = max(videoScale, 1.0)
          pinchStartOffset = videoOffset
          // Pinch always wins over the one-finger gesture family. A short
          // suppression tail prevents one finger from a just-finished pinch
          // being interpreted as brightness/volume or seek.
          gestureStartBrightness = nil
          gestureStartVolume = nil
          isGestureInteracting = false
          controlsTask?.cancel()
          cancelInteractiveDismissForPinch()
        }

        singleFingerGestureSuppressedUntil = ProcessInfo.processInfo.systemUptime + 0.22
        let rawScale = pinchStartScale * value.magnification
        let nextScale = rubberBandedVideoScale(rawScale)
        let anchor = CGSize(
          width: (value.startAnchor.x - 0.5) * proxy.size.width,
          height: (value.startAnchor.y - 0.5) * proxy.size.height
        )
        let anchoredOffset = CGSize(
          width: pinchStartOffset.width + anchor.width * (pinchStartScale - nextScale),
          height: pinchStartOffset.height + anchor.height * (pinchStartScale - nextScale)
        )
        videoScale = nextScale
        videoOffset = rubberBandedVideoOffset(anchoredOffset, scale: nextScale, viewport: proxy.size)
      }
      .onEnded { value in
        guard appState.playerGesturesEnabled, !isLocked else {
          isPinchInteracting = false
          return
        }

        singleFingerGestureSuppressedUntil = ProcessInfo.processInfo.systemUptime + 0.24
        let rawScale = pinchStartScale * value.magnification
        let targetScale = min(max(rawScale, 1.0), 3.0)
        let targetOffset = clampedVideoOffset(videoOffset, scale: targetScale, viewport: proxy.size)

        // iOS Photos-style rubber band: the picture may compress below its
        // natural size while the fingers are still down, but it never rests
        // there. Releasing below 1x springs both scale and position home.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.12)) {
          videoScale = targetScale
          videoOffset = targetScale <= 1.001 ? .zero : targetOffset
        }

        pinchStartScale = targetScale
        pinchStartOffset = targetScale <= 1.001 ? .zero : targetOffset
        isPinchInteracting = false
        scheduleControlsHide()
      }
  }

  private func rubberBandedVideoScale(_ rawScale: CGFloat) -> CGFloat {
    if rawScale < 1.0 {
      // Increasing resistance as the user squeezes past the natural size.
      // The temporary floor is intentionally lower than the resting minimum
      // so the release has a visible, premium-feeling spring-back distance.
      let overshoot = min(1.0 - rawScale, 0.64)
      return max(0.78, 1.0 - overshoot * 0.34)
    }
    if rawScale > 3.0 {
      let overshoot = min(rawScale - 3.0, 1.5)
      return min(3.24, 3.0 + overshoot * 0.16)
    }
    return rawScale
  }

  private func clampedVideoOffset(_ offset: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
    guard scale > 1.001 else { return .zero }
    let limits = videoPanLimits(scale: scale, viewport: viewport)
    return CGSize(
      width: min(max(offset.width, -limits.width), limits.width),
      height: min(max(offset.height, -limits.height), limits.height)
    )
  }

  private func rubberBandedVideoOffset(_ offset: CGSize, scale: CGFloat, viewport: CGSize) -> CGSize {
    guard scale > 1.001 else { return .zero }
    let limits = videoPanLimits(scale: scale, viewport: viewport)
    return CGSize(
      width: rubberBandedBoundedValue(offset.width, limit: limits.width, dimension: viewport.width),
      height: rubberBandedBoundedValue(offset.height, limit: limits.height, dimension: viewport.height)
    )
  }

  private func videoPanLimits(scale: CGFloat, viewport: CGSize) -> CGSize {
    let contentSize = fittedVideoContentSize(in: viewport)
    return CGSize(
      width: max(0, contentSize.width * scale - viewport.width) * 0.5,
      height: max(0, contentSize.height * scale - viewport.height) * 0.5
    )
  }

  private func fittedVideoContentSize(in viewport: CGSize) -> CGSize {
    // Aspect-fill is already cropped to the player's viewport. In aspect-fit,
    // clamp against the visible video rather than the full black player layer;
    // this prevents wide movies from being dragged deep into letterbox space.
    guard videoLayout == .fit,
      let source = model?.videoDisplaySize,
      source.width > 0,
      source.height > 0,
      viewport.width > 0,
      viewport.height > 0
    else { return viewport }

    let factor = min(viewport.width / source.width, viewport.height / source.height)
    return CGSize(width: source.width * factor, height: source.height * factor)
  }

  private func rubberBandedBoundedValue(_ value: CGFloat, limit: CGFloat, dimension: CGFloat) -> CGFloat {
    let magnitude = abs(value)
    guard magnitude > limit else { return value }
    let overflow = magnitude - limit
    let resistanceLength = max(dimension * 0.18, 48)
    let resisted = (overflow * 0.42 * resistanceLength) / (resistanceLength + overflow)
    return (value < 0 ? -1 : 1) * (limit + resisted)
  }

  @ViewBuilder
  private func playerChrome(proxy: GeometryProxy) -> some View {
    VStack(spacing: 0) {
      topOverlay(proxy: proxy)
      Spacer(minLength: 0)
      bottomOverlay(proxy: proxy)
    }
  }

  private func gestureSurface(isLeft: Bool, proxy: GeometryProxy) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .frame(maxWidth: .infinity)
      .gesture(mediaTapGesture {
        guard appState.playerGesturesEnabled else { return }
        seekBy(isLeft ? -Double(appState.doubleTapSeekSeconds) : Double(appState.doubleTapSeekSeconds))
      })
  }

  private func mediaTapGesture(doubleTapAction: @escaping () -> Void) -> some Gesture {
    TapGesture(count: 2)
      .exclusively(before: TapGesture(count: 1))
      .onEnded { value in
        switch value {
        case .first:
          doubleTapAction()
        case .second:
          toggleControls()
        }
      }
  }

  private func videoDragGesture(proxy: GeometryProxy) -> some Gesture {
    let availableHeight = max(proxy.size.height, 1)
    let availableWidth = max(proxy.size.width, 1)
    let isLandscape = availableWidth > availableHeight

    return DragGesture(minimumDistance: 4)
      .onChanged { value in
        guard appState.playerGesturesEnabled, !isPinchInteracting else { return }
        guard ProcessInfo.processInfo.systemUptime >= singleFingerGestureSuppressedUntil else { return }

        // A zoomed video always owns one-finger movement. Interactive dismiss
        // is intentionally disabled above 1x so panning a magnified frame can
        // never accidentally leave the player.
        if videoScale > 1.001 {
          if dragIntent != .zoomPan {
            dragIntent = .zoomPan
            isGestureInteracting = true
            panStartOffset = videoOffset
            gestureStartBrightness = nil
            gestureStartVolume = nil
            controlsTask?.cancel()
          }
          let candidate = CGSize(
            width: panStartOffset.width + value.translation.width,
            height: panStartOffset.height + value.translation.height
          )
          videoOffset = rubberBandedVideoOffset(candidate, scale: videoScale, viewport: proxy.size)
          return
        }

        if !isLandscape {
          classifyPortraitDragIfNeeded(value)
          guard dragIntent == .portraitDismiss else { return }
          updatePortraitDismissDrag(value, viewport: proxy.size)
          return
        }

        let dx = value.translation.width
        let dy = value.translation.height
        classifyLandscapeDragIfNeeded(value, availableWidth: availableWidth)

        if dragIntent == .landscapeSeek {
          isGestureInteracting = true
          controlsTask?.cancel()
          let delta = Double(dx / availableWidth) * 180
          updateContinuousGestureHUD(
            delta < 0 ? "后退  \(Int(abs(delta).rounded())) 秒" : "前进  \(Int(abs(delta).rounded())) 秒",
            systemName: delta < 0 ? "gobackward" : "goforward"
          )
          return
        }

        guard dragIntent == .landscapeBrightness || dragIntent == .landscapeVolume else { return }
        if !isGestureInteracting {
          isGestureInteracting = true
          controlsTask?.cancel()
          gestureStartBrightness = UIScreen.main.brightness
          gestureStartVolume = activeVolume
        }

        let normalizedDelta = -dy / availableHeight * 1.35
        if dragIntent == .landscapeBrightness {
          let start = gestureStartBrightness ?? UIScreen.main.brightness
          let next = min(max(start + normalizedDelta, 0), 1)
          UIScreen.main.brightness = next
          updateContinuousGestureHUD(
            "亮度  \(Int((next * 100).rounded()))%",
            systemName: "sun.max.fill"
          )
        } else {
          let start = CGFloat(gestureStartVolume ?? activeVolume)
          let next = min(max(start + normalizedDelta, 0), 1)
          setActiveVolume(Float(next))
          updateContinuousGestureHUD(
            "音量  \(Int((next * 100).rounded()))%",
            systemName: "speaker.wave.3.fill"
          )
        }
      }
      .onEnded { value in
        guard appState.playerGesturesEnabled else { return }
        if isPinchInteracting || ProcessInfo.processInfo.systemUptime < singleFingerGestureSuppressedUntil {
          resetDragIntent()
          return
        }

        if dragIntent == .zoomPan || videoScale > 1.001 {
          let residualProjection = CGSize(
            width: (value.predictedEndTranslation.width - value.translation.width) * 0.42,
            height: (value.predictedEndTranslation.height - value.translation.height) * 0.42
          )
          let projectedOffset = CGSize(
            width: videoOffset.width + residualProjection.width,
            height: videoOffset.height + residualProjection.height
          )
          let targetOffset = clampedVideoOffset(projectedOffset, scale: videoScale, viewport: proxy.size)
          withAnimation(.spring(duration: 0.40, bounce: 0.0)) {
            videoOffset = targetOffset
          }
          panStartOffset = targetOffset
          resetDragIntent()
          scheduleControlsHide()
          return
        }

        if !isLandscape {
          if dragIntent == .portraitDismiss {
            finishPortraitDismissDrag(value, viewport: proxy.size)
          } else {
            resetDragIntent()
          }
          return
        }

        if dragIntent == .landscapeSeek {
          let delta = Double(value.translation.width / availableWidth) * 180
          if abs(delta) > 2 { seekBy(delta) }
        }

        if isGestureInteracting { finishContinuousGestureHUD() }
        resetDragIntent()
        scheduleControlsHide()
      }
  }

  private func classifyPortraitDragIfNeeded(_ value: DragGesture.Value) {
    guard dragIntent == .undecided else { return }
    let dx = value.translation.width
    let dy = value.translation.height
    guard hypot(dx, dy) >= 12 else { return }

    // Acquire the viewer only after the gesture has a clear vertical intent.
    // Once acquired, movement remains bidirectional so reversing across the
    // touch origin never changes resistance or creates a sticky top edge.
    if abs(dy) > abs(dx) * 1.08 {
      dragIntent = .portraitDismiss
    } else if abs(dx) > abs(dy) {
      dragIntent = .ignored
    }
  }

  private func classifyLandscapeDragIfNeeded(_ value: DragGesture.Value, availableWidth: CGFloat) {
    guard dragIntent == .undecided else { return }
    let dx = value.translation.width
    let dy = value.translation.height
    guard hypot(dx, dy) >= 11 else { return }

    if abs(dx) > abs(dy) * 1.08 {
      dragIntent = .landscapeSeek
    } else if abs(dy) > abs(dx) * 1.08 {
      dragIntent = value.startLocation.x < availableWidth * 0.5
        ? .landscapeBrightness
        : .landscapeVolume
    }
  }

  private func resetDragIntent() {
    dragIntent = .undecided
    gestureStartBrightness = nil
    gestureStartVolume = nil
    isGestureInteracting = false
  }

  @MainActor
  private func updatePortraitDismissDrag(_ value: DragGesture.Value, viewport: CGSize) {
    guard !isScrubbing,
      !isControlsInteractionActive,
      !showSettingsPanel,
      !showSpeedPanel,
      !showQueuePanel,
      !showPlaybackHUD,
      !showInfo
    else { return }

    if !isDismissDragging {
      isDismissSettling = false
      isDismissDragging = true
      dismissControlsWereVisible = controlsVisible
      dismissRestoreTask?.cancel()
      controlsTask?.cancel()
      hudTask?.cancel()
      gestureHUD = nil
    }

    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      // Direct manipulation must remain exactly under the finger. Springing is
      // reserved for finishPortraitDismissDrag after the touch has ended.
      dismissDragOffset = rubberBandedDismissTranslation(value.translation, viewport: viewport)
    }
  }

  @MainActor
  private func cancelInteractiveDismissForPinch() {
    guard isDismissDragging || dismissDragOffset != .zero else { return }
    isDismissDragging = false
    isDismissSettling = false
    resetDragIntent()
    dismissRestoreTask?.cancel()
    withAnimation(.spring(response: 0.24, dampingFraction: 0.90)) {
      dismissDragOffset = .zero
    }
  }

  private func rubberBandedDismissTranslation(_ translation: CGSize, viewport: CGSize) -> CGSize {
    return CGSize(
      width: rubberBandedDismissAxis(translation.width, dimension: viewport.width),
      height: rubberBandedDismissAxis(translation.height, dimension: viewport.height)
    )
  }

  private func rubberBandedDismissAxis(_ value: CGFloat, dimension: CGFloat) -> CGFloat {
    let sign: CGFloat = value < 0 ? -1 : 1
    let magnitude = abs(value)
    // Stay directly under the finger throughout the useful dismissal range.
    // Resistance begins only after the media is already mostly off-screen,
    // preventing the "magnetic" edge sensation during a direction reversal.
    let threshold = max(dimension, 1) * 0.72
    guard magnitude > threshold else { return value }
    let resistance = max(dimension, 1) * 0.24
    let overflow = magnitude - threshold
    return sign * (threshold + resistance * (1 - exp(-overflow / resistance)))
  }

  @MainActor
  private func finishPortraitDismissDrag(_ value: DragGesture.Value, viewport: CGSize) {
    guard isDismissDragging else {
      resetDragIntent()
      return
    }

    let height = max(viewport.height, 1)
    let actualY = value.translation.height
    let projectedY = value.predictedEndTranslation.height
    let dismissDistance = min(max(height * 0.22, 140), 220)
    let hasMeaningfulOffset = abs(actualY) > 8
    let velocityContinuesCurrentDirection = !hasMeaningfulOffset
      || value.velocity.height * actualY >= 0
    let projectionStaysOnCurrentSide = !hasMeaningfulOffset
      || projectedY * actualY >= 0
    let fastVerticalFlick = abs(value.velocity.height) > 650
      && abs(projectedY) > dismissDistance * 0.72
      && projectionStaysOnCurrentSide
      && velocityContinuesCurrentDirection
    let shouldDismiss = (abs(actualY) >= dismissDistance && velocityContinuesCurrentDirection)
      || (abs(projectedY) >= dismissDistance * 1.12
        && projectionStaysOnCurrentSide
        && velocityContinuesCurrentDirection)
      || fastVerticalFlick

    dismissRestoreTask?.cancel()
    isDismissDragging = false
    isDismissSettling = true

    if shouldDismiss {
      UIImpactFeedbackGenerator(style: .soft).impactOccurred()

      // Keep the rendered surface at the exact release position and hand that
      // snapshot straight to the presentation dismissal. Moving it off-screen
      // first creates a second, disconnected animation whose starting edge is
      // undefined.
      dismiss()
      return
    }

    withAnimation(.spring(duration: 0.42, bounce: 0.0)) {
      dismissDragOffset = .zero
    }

    let shouldRestoreControls = dismissControlsWereVisible
    dismissRestoreTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(420))
      guard !Task.isCancelled else { return }
      isDismissSettling = false
      if shouldRestoreControls {
        controlsVisible = true
        scheduleControlsHide()
      } else {
        controlsVisible = false
      }
      resetDragIntent()
    }
  }

  private func lockShield(proxy: GeometryProxy) -> some View {
    ZStack(alignment: .trailing) {
      Color.clear
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture { showGestureHUD("控制已锁定", systemName: "lock.fill") }

      Button {
        isLocked = false
        controlsVisible = true
        showGestureHUD("已解锁", systemName: "lock.open.fill")
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
      playerIconButton("chevron.left") {
        pauseActivePlayer()
        dismiss()
      }
      .accessibilityLabel("返回")

      Spacer(minLength: 6)

      playerIconButton("ellipsis") {
        openSettingsPanel()
      }
      .accessibilityLabel("播放设置")
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, landscape ? 18 : 12))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, landscape ? 18 : 12))
    .padding(
      .top,
      landscape
        ? max(proxy.safeAreaInsets.top + 18, 26)
        : max(proxy.safeAreaInsets.top + 20, 36)
    )
    .padding(.bottom, landscape ? 20 : 12)
    .background(
      LinearGradient(
        colors: [.black.opacity(landscape ? 0.36 : 0.46), .clear],
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

      if playlist.count > 1 {
        settingsActionButton("播放列表", systemName: "rectangle.stack.badge.play") {
          openQueuePanel()
        }
      }

      settingsActionButton(showPlaybackHUD ? "关闭 HUD" : "播放 HUD", systemName: "waveform.path.ecg") {
        showPlaybackHUD.toggle()
        keepControlsDuringInteraction()
      }

      HStack(spacing: 8) {
        if !useVLC {
          settingsAirPlayButton()
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

      HStack(spacing: 8) {
        settingsActionButton("详情", systemName: "info.circle") {
          closeSettingsPanel(scheduleHide: false)
          showInfo = true
        }
        settingsActionButton("锁定控制", systemName: "lock.fill") {
          closeSettingsPanel(scheduleHide: false)
          showSpeedPanel = false
          showQueuePanel = false
          isLocked = true
          controlsVisible = false
          controlsTask?.cancel()
          showGestureHUD("控制已锁定", systemName: "lock.fill")
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

  private func settingsAirPlayButton() -> some View {
    AirPlayRoutePickerButton { presented in
      isRoutePickerPresented = presented
      if presented {
        keepControlsDuringInteraction()
      } else {
        scheduleControlsHide()
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 40)
    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityLabel("AirPlay")
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
        HStack(alignment: .bottom, spacing: landscape ? 13 : 10) {
          compactPlayPauseButton()
          timeline(model: model)
            .frame(maxWidth: .infinity)
          muteButton()
        }
        // Keep horizontal geometry stable while seeking so the timestamp does
        // not jump when the glass card expands around the same finger position.
        .padding(.horizontal, 11)
        .padding(.vertical, isScrubbing ? 10 : 6)
        .background {
          RoundedRectangle(cornerRadius: isScrubbing ? 24 : 20, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
              RoundedRectangle(cornerRadius: isScrubbing ? 24 : 20, style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [.white.opacity(isScrubbing ? 0.13 : 0.09), .white.opacity(0.025)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )
            }
        }
        .overlay {
          RoundedRectangle(cornerRadius: isScrubbing ? 24 : 20, style: .continuous)
            .stroke(.white.opacity(isScrubbing ? 0.20 : 0.13), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(isScrubbing ? 0.30 : 0.22), radius: isScrubbing ? 18 : 12, y: 6)
        .animation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.08), value: isScrubbing)
      }
    }
    .padding(.leading, max(proxy.safeAreaInsets.leading, landscape ? 24 : 16))
    .padding(.trailing, max(proxy.safeAreaInsets.trailing, landscape ? 24 : 16))
    .padding(.top, landscape ? 30 : 24)
    .padding(.bottom, max(proxy.safeAreaInsets.bottom, landscape ? 10 : 14) + 4)
    .background(
      LinearGradient(
        colors: [.clear, .black.opacity(landscape ? 0.58 : 0.70)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func compactPlayPauseButton() -> some View {
    Button {
      toggleActivePlayback(userInitiated: true)
      controlsVisible = true
      scheduleControlsHide()
    } label: {
      Image(systemName: activeIsPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 17, weight: .semibold))
        .contentTransition(.symbolEffect)
        .foregroundStyle(.white)
        .frame(width: 42, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(PlayerPressScaleStyle(pressedScale: 0.92))
    .accessibilityLabel(activeIsPlaying ? "暂停" : "播放")
  }

  private func muteButton() -> some View {
    return Button {
      if isPlayerMuted {
        setActiveVolume(max(volumeBeforeMute, 0.35))
      } else {
        volumeBeforeMute = max(activeVolume, 0.05)
        setActiveVolume(0)
      }
      UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.62)
      controlsVisible = true
      scheduleControlsHide()
    } label: {
      Image(systemName: isPlayerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .font(.system(size: 16, weight: .semibold))
        .contentTransition(.symbolEffect)
        .foregroundStyle(.white)
        .frame(width: 42, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(PlayerPressScaleStyle(pressedScale: 0.92))
    .accessibilityLabel(isPlayerMuted ? "恢复声音" : "静音")
  }

  private func timeline(model: PlayerModel) -> some View {
    let remaining = max(activeDuration - scrubValue, 0)

    return VStack(spacing: isScrubbing ? 5 : 0) {
      if isScrubbing {
        HStack(spacing: 8) {
          Text(formatPreciseTime(scrubValue))
          Spacer(minLength: 8)
          Text("−\(formatPreciseTime(remaining))")
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1)
        .contentTransition(.numericText())
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前位置 \(formatPreciseTime(scrubValue))，剩余 \(formatPreciseTime(remaining))")
      }

      GeometryReader { proxy in
        let width = max(proxy.size.width, 1)
        let duration = max(activeDuration, 1)
        let current = min(max(isScrubbing ? scrubValue : activeCurrentTime, 0), duration)
        let buffered = min(max(activeBufferedUntil, 0), duration)
        let playedProgress = CGFloat(current / duration)
        let bufferedProgress = CGFloat(buffered / duration)
        let playedX = width * playedProgress
        let bufferedX = width * bufferedProgress
        let trackHeight: CGFloat = isScrubbing ? 6 : 4

        ZStack(alignment: .leading) {
          Capsule()
            .fill(.white.opacity(isScrubbing ? 0.20 : 0.32))
            .frame(height: trackHeight)

          if !isScrubbing, !useVLC {
            Capsule()
              .fill(.white.opacity(0.48))
              .frame(width: bufferedX, height: trackHeight)
          }

          Capsule()
            .fill(isScrubbing ? Color.white.opacity(0.70) : Color.white)
            .frame(width: playedX, height: trackHeight)

          if !isScrubbing, appState.showChapterMarkers, activeDuration > 0 {
            ForEach(activeChapters) { chapter in
              let markerX = width * CGFloat(min(max(chapter.start / duration, 0), 1))
              Rectangle()
                .fill(.white.opacity(0.70))
                .frame(width: 1, height: 9)
                .offset(x: min(max(markerX, 0), width - 1))
            }
          }
        }
        .frame(maxHeight: .infinity)
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: isScrubbing)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
          if isScrubbing, appState.timelinePreviewEnabled, !useVLC {
            let previewWidth: CGFloat = 168
            let clampedCenterX = min(max(playedX, previewWidth * 0.5), max(width - previewWidth * 0.5, previewWidth * 0.5))

            VStack(spacing: 5) {
              // Mirror the exact frame currently presented by the main AVPlayer
              // layer. Unlike AVAssetImageGenerator this cannot drift to a
              // neighboring timestamp and it creates zero extra Range requests.
              SystemPlayerScrubPreviewView(presentationController: systemPresentationController)
                .frame(width: previewWidth, height: 94)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

              Text(formatTime(scrubValue))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            }
            .padding(6)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .offset(x: clampedCenterX - width * 0.5, y: -118)
            .allowsHitTesting(false)
          }
        }
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              if !isScrubbing {
                isScrubbing = true
                controlsTask?.cancel()
                if useVLC {
                  scrubWasPlaying = vlcController.beginInteractiveScrub()
                } else {
                  scrubWasPlaying = model.beginInteractiveScrub()
                }
              }
              let x = min(max(value.location.x, 0), width)
              scrubValue = Double(x / width) * duration

              // The timeline value follows the finger immediately, while the
              // decoder uses a coalesced chase seek so stale intermediate
              // positions never build up behind the user's gesture.
              if useVLC {
                vlcController.interactiveScrub(to: scrubValue)
              } else {
                model.interactiveScrub(to: scrubValue)
              }
            }
            .onEnded { value in
              let x = min(max(value.location.x, 0), width)
              scrubValue = Double(x / width) * duration
              if useVLC {
                vlcController.endInteractiveScrub(to: scrubValue, resumeAfter: scrubWasPlaying)
              } else {
                model.endInteractiveScrub(to: scrubValue, resumeAfter: scrubWasPlaying)
              }
              scrubWasPlaying = false
              isScrubbing = false
              updateRemotePlaybackInfo()
              scheduleControlsHide()
            }
        )
      }
      .frame(height: 44)
    }
    .animation(.spring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.08), value: isScrubbing)
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
      .buttonStyle(PlayerPressScaleStyle(pressedScale: 0.92))
  }

  private func playerIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 40, height: 40)
      .background {
        Circle()
          .fill(.ultraThinMaterial)
          .overlay {
            Circle()
              .fill(
                LinearGradient(
                  colors: [.white.opacity(0.16), .white.opacity(0.035)],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing
                )
              )
          }
      }
      .overlay { Circle().stroke(.white.opacity(0.20), lineWidth: 0.7) }
      .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
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
    let now = ProcessInfo.processInfo.systemUptime
    // The center control and the transparent gesture surface overlap by design.
    // One physical long press must still toggle exactly once.
    guard !isPinchInteracting,
      now >= singleFingerGestureSuppressedUntil,
      now - lastFavoriteToggleUptime > 0.36
    else { return }
    lastFavoriteToggleUptime = now

    let wasFavorite = appState.libraryStore.isFavorite(currentItem)
    appState.libraryStore.toggleFavorite(currentItem)
    favoriteHUDIsRemoval = wasFavorite

    let feedback = UIImpactFeedbackGenerator(style: .medium)
    feedback.prepare()
    feedback.impactOccurred(intensity: 0.88)

    favoriteHUDTask?.cancel()
    showFavoriteHeart = false
    withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
      showFavoriteHeart = true
    }
    favoriteHUDTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(620))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.18)) {
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
    subtitleLoadTask?.cancel()
    auxiliaryLoadTask?.cancel()
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
    if persist {
      appState.preferredPlaybackRate = safe
      let feedback = UISelectionFeedbackGenerator()
      feedback.prepare()
      feedback.selectionChanged()
      showPlaybackFeedback(
        systemName: "speedometer",
        title: safe == 1 ? "正常速度" : formatRate(Double(safe))
      )
    }
    withActiveEngine { $0.engineSetPlaybackRate(safe) }
    updateRemotePlaybackInfo()
  }

  @MainActor
  private func toggleActivePlayback(userInitiated: Bool = false) {
    withActiveEngine { $0.engineTogglePlayback() }
    updateRemotePlaybackInfo()
    if userInitiated {
      let feedback = UIImpactFeedbackGenerator(style: .soft)
      feedback.prepare()
      feedback.impactOccurred(intensity: 0.72)
    }
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
    isPlayerMuted = safe <= 0.001
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

  private var activeIsScrubLoading: Bool {
    useVLC ? vlcController.isInteractiveScrubLoading : (model?.isInteractiveScrubLoading ?? false)
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
        if cues.isEmpty {
          showGestureHUD("字幕文件没有可识别时间轴", systemName: "captions.bubble.fill")
        }
      } catch {
        guard !Task.isCancelled, currentItem.id == expectedID else { return }
        selectedExternalSubtitleID = nil
        externalSubtitleCues = []
        showGestureHUD("字幕读取失败", systemName: "exclamationmark.triangle.fill")
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
      withAnimation(.spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06)) {
        controlsVisible = true
      }
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
    pinchStartOffset = .zero
    videoOffset = .zero
    panStartOffset = .zero
    dismissDragOffset = .zero
    isDismissDragging = false
    isDismissSettling = false
    dragIntent = .undecided
    dismissRestoreTask?.cancel()
    isPinchInteracting = false
    singleFingerGestureSuppressedUntil = 0
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
    showGestureHUD(
      seconds < 0 ? "后退 \(magnitude) 秒" : "前进 \(magnitude) 秒",
      systemName: seconds < 0 ? "gobackward" : "goforward"
    )
    scheduleControlsHide()
  }

  @MainActor
  private func toggleControls() {
    let now = ProcessInfo.processInfo.systemUptime
    guard !isLocked,
      !isPinchInteracting,
      !isDismissMotionActive,
      now >= singleFingerGestureSuppressedUntil
    else { return }
    let revealing = !controlsVisible
    withAnimation(
      revealing
        ? .spring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.06)
        : .easeOut(duration: 0.22)
    ) {
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

      withAnimation(.easeOut(duration: 0.24)) {
        controlsVisible = false
      }
    }
  }

  @MainActor
  private func updateContinuousGestureHUD(_ message: String, systemName: String) {
    hudTask?.cancel()
    gestureHUDSystemName = systemName
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
  private func showGestureHUD(_ message: String, systemName: String = "checkmark.circle.fill") {
    hudTask?.cancel()
    gestureHUDSystemName = systemName
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

  @MainActor
  private func showPlaybackFeedback(systemName: String, title: String) {
    playbackFeedbackTask?.cancel()
    playbackFeedback = nil
    withAnimation(.spring(response: 0.24, dampingFraction: 0.76)) {
      playbackFeedback = PlayerPlaybackFeedback(systemName: systemName, title: title)
    }
    playbackFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(620))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.16)) {
        playbackFeedback = nil
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

  private func formatPreciseTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00.000" }
    let totalMilliseconds = max(0, Int((seconds * 1_000).rounded()))
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds % 3_600_000) / 60_000
    let secs = (totalMilliseconds % 60_000) / 1_000
    let milliseconds = totalMilliseconds % 1_000
    return hours > 0
      ? String(format: "%d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
      : String(format: "%02d:%02d.%03d", minutes, secs, milliseconds)
  }

}

/// Keeps high-frequency pinch, pan, and interactive-dismiss transforms on a
/// dedicated rendering leaf. Player controls and panels remain sibling views,
/// so direct manipulation does not force their expensive material hierarchies
/// into the same animated render group.
private struct PlayerMediaRenderingSurface<Media: View, Overlay: View>: View {
  let viewport: CGSize
  let videoScale: CGFloat
  let videoOffset: CGSize
  let dismissScale: CGFloat
  let dismissOffset: CGSize
  let dismissCornerRadius: CGFloat
  let dismissProgress: CGFloat
  let media: Media
  let overlay: Overlay

  init(
    viewport: CGSize,
    videoScale: CGFloat,
    videoOffset: CGSize,
    dismissScale: CGFloat,
    dismissOffset: CGSize,
    dismissCornerRadius: CGFloat,
    dismissProgress: CGFloat,
    @ViewBuilder media: () -> Media,
    @ViewBuilder overlay: () -> Overlay
  ) {
    self.viewport = viewport
    self.videoScale = videoScale
    self.videoOffset = videoOffset
    self.dismissScale = dismissScale
    self.dismissOffset = dismissOffset
    self.dismissCornerRadius = dismissCornerRadius
    self.dismissProgress = dismissProgress
    self.media = media()
    self.overlay = overlay()
  }

  var body: some View {
    ZStack {
      media
        .frame(width: viewport.width, height: viewport.height)
        .scaleEffect(videoScale, anchor: .center)
        .offset(videoOffset)
        .frame(width: viewport.width, height: viewport.height)
        .background(Color.black)
        .clipped()
        .ignoresSafeArea()

      overlay
    }
    .frame(width: viewport.width, height: viewport.height)
    .scaleEffect(dismissScale, anchor: .center)
    .offset(dismissOffset)
    .clipShape(
      RoundedRectangle(cornerRadius: dismissCornerRadius, style: .continuous)
    )
    .shadow(
      color: .black.opacity(Double(dismissProgress) * 0.22),
      radius: dismissProgress * 22,
      y: dismissProgress * 9
    )
    .allowsHitTesting(false)
  }
}

private struct PlayerPlaybackFeedback: Equatable {
  let systemName: String
  let title: String
}

private struct PlayerPlaybackFeedbackView: View {
  let feedback: PlayerPlaybackFeedback

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: feedback.systemName)
        .font(.system(size: 42, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
      Text(feedback.title)
        .font(.subheadline.weight(.semibold))
    }
    .foregroundStyle(.white)
    .frame(width: 126, height: 116)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .stroke(.white.opacity(0.12), lineWidth: 0.7)
    }
    .shadow(color: .black.opacity(0.26), radius: 22, y: 9)
    .accessibilityElement(children: .combine)
  }
}

private struct PlayerGestureFeedbackView: View {
  let systemName: String
  let message: String

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemName)
        .font(.system(size: 19, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .frame(width: 24)
      Text(message)
        .font(.subheadline.monospacedDigit().weight(.semibold))
        .lineLimit(1)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .frame(minWidth: 112, minHeight: 48)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(.white.opacity(0.10), lineWidth: 0.7)
    }
    .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    .accessibilityElement(children: .combine)
  }
}

private struct PlayerPressScaleStyle: ButtonStyle {
  var pressedScale: CGFloat = 0.94

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? pressedScale : 1)
      .opacity(configuration.isPressed ? 0.86 : 1)
      .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
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
          LabeledContent("画面中间双击", value: "播放 / 暂停")
          LabeledContent("画面中间长按", value: "收藏 / 取消收藏")
          LabeledContent("双指缩放", value: "放大 / 回弹")
          LabeledContent("放大后拖动", value: "自由移动画面")
          LabeledContent("横屏左侧上下滑", value: "亮度")
          LabeledContent("横屏右侧上下滑", value: "播放音量")
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
