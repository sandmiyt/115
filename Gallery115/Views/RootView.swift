import SwiftUI

enum AppTab: Hashable {
  case home
  case library
  case favorites
  case recent
  case settings
}

struct RootView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var homeLogoFrame: CGRect = .zero
  @State private var launchHeroTravel: CGFloat = 0
  @State private var launchHeroScaleProgress: CGFloat = 0
  @State private var launchHeroBackdropProgress: CGFloat = 0
  @State private var launchHeroLift: CGFloat = 0
  @State private var launchHeroVisible = true
  @State private var launchHeroStarted = false

  private var isPrivacyLocked: Bool {
    appState.faceIDEnabled && !appState.isAppUnlocked
  }

  private var homeLogoReveal: CGFloat {
    guard launchHeroVisible else { return 1 }
    let arrival = (launchHeroTravel - 0.80) / 0.20
    let clamped = min(max(arrival, 0), 1)
    return clamped * clamped * (3 - 2 * clamped)
  }

  var body: some View {
    ZStack {
      // Keep the main hierarchy alive while locked so returning from the
      // background does not reset the selected tab, navigation stack, or an
      // active full-screen player. Sensitive content is heavily blurred and
      // cannot receive touches until biometric authentication succeeds.
      MainTabView(homeLogoReveal: homeLogoReveal)
        .blur(radius: isPrivacyLocked ? 28 : 0)
        .scaleEffect(isPrivacyLocked ? 1.015 : 1)
        .allowsHitTesting(!isPrivacyLocked)
        .accessibilityHidden(isPrivacyLocked)

      if isPrivacyLocked {
        Rectangle()
          .fill(.regularMaterial)
          .ignoresSafeArea()
          .overlay(Color.black.opacity(0.12).ignoresSafeArea())
          .zIndex(9_999)

        AppLockView()
          .zIndex(10_000)
      }
    }
    .coordinateSpace(name: CinevaLaunchHeroSpace.name)
    .onPreferenceChange(HomeLogoFramePreferenceKey.self) { frame in
      guard frame.width > 1, frame.height > 1 else { return }
      homeLogoFrame = frame
      startLaunchHeroIfReady()
    }
    .onChange(of: appState.isAppUnlocked) { _, unlocked in
      if unlocked { startLaunchHeroIfReady() }
    }
    .overlay {
      if launchHeroVisible, appState.isAppUnlocked, homeLogoFrame.width > 1 {
        LaunchHeroOverlay(
          destination: homeLogoFrame,
          travel: launchHeroTravel,
          scaleProgress: launchHeroScaleProgress,
          backdropProgress: launchHeroBackdropProgress,
          lift: launchHeroLift
        )
          .allowsHitTesting(false)
          .zIndex(20_000)
      }
    }
  }

  private func startLaunchHeroIfReady() {
    guard launchHeroVisible, !launchHeroStarted, appState.isAppUnlocked, homeLogoFrame.width > 1 else { return }
    launchHeroStarted = true

    Task { @MainActor in
      // Hold the first SwiftUI frame briefly so it visually continues the
      // system launch screen instead of snapping immediately into motion.
      try? await Task.sleep(for: .milliseconds(90))

      if reduceMotion {
        withAnimation(.easeOut(duration: 0.20)) {
          launchHeroTravel = 1
          launchHeroScaleProgress = 1
          launchHeroBackdropProgress = 1
          launchHeroLift = 1
        }
        try? await Task.sleep(for: .milliseconds(220))
      } else {
        // A tiny lift gives the mark visual "mass" before it starts moving.
        // It is deliberately subtle: the launch should feel tactile, not showy.
        withAnimation(.smooth(duration: 0.16, extraBounce: 0.0)) {
          launchHeroLift = 1
        }

        try? await Task.sleep(for: .milliseconds(72))

        // Separate tracks create a more system-like shared-element transition:
        // position stays calm and continuous, while size uses a small snappy
        // overshoot so the mark appears to magnetically settle into Home.
        withAnimation(.smooth(duration: 0.56, extraBounce: 0.0)) {
          launchHeroTravel = 1
        }
        withAnimation(.snappy(duration: 0.48, extraBounce: 0.055)) {
          launchHeroScaleProgress = 1
        }
        withAnimation(.easeOut(duration: 0.46)) {
          launchHeroBackdropProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(650))
      }

      launchHeroVisible = false
    }
  }
}

private enum CinevaLaunchHeroSpace {
  static let name = "cineva.launch.hero.space"
}

private struct HomeLogoFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next.width > 1, next.height > 1 { value = next }
  }
}

private struct LaunchHeroOverlay: View {
  let destination: CGRect
  let travel: CGFloat
  let scaleProgress: CGFloat
  let backdropProgress: CGFloat
  let lift: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let startCenter = CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
      let endCenter = CGPoint(x: destination.midX, y: destination.midY)
      let t = min(max(travel, 0), 1)
      let backdrop = min(max(backdropProgress, 0), 1)
      let liftAmount = min(max(lift, 0), 1) * (1 - t)

      // A shallow bezier arc makes the icon feel like it is being attracted to
      // the Home mark instead of sliding along a ruler-straight diagonal.
      let distanceX = endCenter.x - startCenter.x
      let distanceY = endCenter.y - startCenter.y
      let control1 = CGPoint(
        x: startCenter.x + distanceX * 0.18,
        y: startCenter.y + distanceY * 0.10 - 10
      )
      let control2 = CGPoint(
        x: endCenter.x - distanceX * 0.10 + 6,
        y: endCenter.y - distanceY * 0.16 + 12
      )
      let pathCenter = cubicPoint(
        from: startCenter,
        control1: control1,
        control2: control2,
        to: endCenter,
        progress: systemEase(t)
      )
      let center = CGPoint(
        x: pathCenter.x,
        y: pathCenter.y - 3.5 * liftAmount
      )

      let destinationSize = max(destination.width, 48)
      // Keep scaleProgress unclamped on purpose. A snappy spring can briefly
      // travel a few percent beyond 1, producing a tiny magnetic settle at the
      // destination without making the position itself bounce.
      let sizeP = max(0, scaleProgress)
      let baseLogoSize = 120 + (destinationSize - 120) * sizeP
      let logoSize = baseLogoSize * (1 + 0.022 * liftAmount)

      // Preserve the launch screen for the first beat, then reveal Home a touch
      // faster near the end so the destination is visually ready before the
      // moving mark crossfades into it.
      let backgroundOpacity = 1 - smoothstep(backdrop)
      let arrival = min(max((t - 0.78) / 0.22, 0), 1)
      let logoOpacity = 1 - smoothstep(arrival)
      let shadowEnergy = (1 - t) * 0.65 + liftAmount * 0.35

      ZStack {
        Color(uiColor: .systemBackground)
          .opacity(backgroundOpacity)
          .ignoresSafeArea()

        Image("LaunchLogo")
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: logoSize, height: logoSize)
          .position(center)
          .opacity(logoOpacity)
          .shadow(
            color: .black.opacity(0.105 * shadowEnergy),
            radius: 15 * shadowEnergy,
            y: 6 * shadowEnergy
          )
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
  }

  private func cubicPoint(
    from p0: CGPoint,
    control1 p1: CGPoint,
    control2 p2: CGPoint,
    to p3: CGPoint,
    progress t: CGFloat
  ) -> CGPoint {
    let u = 1 - t
    let tt = t * t
    let uu = u * u
    let uuu = uu * u
    let ttt = tt * t
    return CGPoint(
      x: uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x,
      y: uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
    )
  }

  private func systemEase(_ value: CGFloat) -> CGFloat {
    let x = min(max(value, 0), 1)
    // Quintic smoothstep has zero velocity and acceleration at both ends. It
    // reads closer to UIKit/SwiftUI system motion than a plain linear lerp.
    return x * x * x * (x * (x * 6 - 15) + 10)
  }

  private func smoothstep(_ value: CGFloat) -> CGFloat {
    let x = min(max(value, 0), 1)
    return x * x * (3 - 2 * x)
  }
}

private struct AppLockView: View {
  @Environment(AppState.self) private var appState
  @State private var isAuthenticating = false

  var body: some View {
    Rectangle()
      .fill(.ultraThinMaterial)
      .ignoresSafeArea()
      .contentShape(Rectangle())
      .onTapGesture {
        authenticate()
      }
  }

  private func authenticate() {
    guard !isAuthenticating else { return }
    isAuthenticating = true
    Task {
      await appState.authenticateIfNeeded()
      isAuthenticating = false
    }
  }
}

private struct MainTabView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(AppState.self) private var appState
  @State private var selectedTab: AppTab = .home
  let homeLogoReveal: CGFloat

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack { HomeView(logoReveal: homeLogoReveal) }
        .tag(AppTab.home)
        .tabItem { Label("首页", systemImage: "house.fill") }

      NavigationStack {
        FolderView(folderID: appState.rootFolderID, title: "资料库")
      }
      .tag(AppTab.library)
      .tabItem { Label("资料库", systemImage: "rectangle.stack.fill") }

      NavigationStack { FavoritesView() }
        .tag(AppTab.favorites)
        .tabItem { Label("收藏", systemImage: "heart.fill") }

      NavigationStack { RecentView() }
        .tag(AppTab.recent)
        .tabItem { Label("最近", systemImage: "clock.fill") }

      NavigationStack { SettingsView() }
        .tag(AppTab.settings)
        .tabItem { Label("设置", systemImage: "gearshape.fill") }
    }
    .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    .toolbarBackground(.visible, for: .tabBar)
    .toolbarColorScheme(colorScheme, for: .tabBar)
  }
}

private struct HomeView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?
  @State private var didCheckConnection = false
  let logoReveal: CGFloat

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        header

        if !appState.libraryStore.recents.isEmpty {
          mediaSection(title: "继续观看", subtitle: "从上次的位置继续") {
            ScrollView(.horizontal) {
              LazyHStack(spacing: 11) {
                ForEach(appState.libraryStore.recents.prefix(12)) { entry in
                  ContinueWatchingCard(entry: entry) {
                    selectedVideo = entry.item
                  }
                }
              }
              .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
          }
        }


      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 34)
    }
    .background(pageBackground.ignoresSafeArea())
    .navigationBarHidden(true)
    .fullScreenCover(item: $selectedVideo) { item in
      PlayerScreen(item: item)
    }
    .task(id: "\(appState.isConfigured)|\(appState.isAppUnlocked)") {
      guard appState.isAppUnlocked, !didCheckConnection, appState.isConfigured else { return }
      didCheckConnection = true
      do {
        try await appState.api.validateCredentials()
        appState.markMediaConnected()
      } catch {
        appState.markMediaOffline()
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      CinevaLogoMark(size: 48)
        .opacity(logoReveal)
        .scaleEffect(0.97 + 0.03 * logoReveal)
        .background {
          GeometryReader { logoProxy in
            Color.clear
              .preference(
                key: HomeLogoFramePreferenceKey.self,
                value: logoProxy.frame(in: .named(CinevaLaunchHeroSpace.name))
              )
          }
        }
      VStack(alignment: .leading, spacing: 2) {
        Text("Cineva")
          .font(.system(size: 29, weight: .bold, design: .rounded))
        Text("稳定挂载的私人影音库")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) {
        Circle().fill(connectionColor).frame(width: 7, height: 7)
        Text(appState.isConfigured ? appState.mediaConnectionState.title : "未连接媒体源")
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(panelBackground, in: Capsule())
    }
    .padding(.top, 6)
  }


  private var connectionColor: Color {
    guard appState.isConfigured else { return .secondary }
    switch appState.mediaConnectionState {
    case .unknown: return .secondary
    case .connected: return .green
    case .cache: return .orange
    case .offline: return .red
    }
  }

  private var pageBackground: Color {
    colorScheme == .dark ? CinevaTheme.darkBackground : Color(uiColor: .systemGroupedBackground)
  }

  private var panelBackground: Color {
    colorScheme == .dark ? CinevaTheme.darkPanel : Color(uiColor: .secondarySystemGroupedBackground)
  }

  @ViewBuilder
  private func mediaSection<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.title3.bold())
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      content()
    }
  }
}

private struct ContinueWatchingCard: View {
  let entry: PlaybackEntry
  let action: () -> Void

  private let cardWidth: CGFloat = 150

  private var progress: Double {
    guard entry.effectiveDuration > 0 else { return 0 }
    return min(max(entry.lastPosition / entry.effectiveDuration, 0), 1)
  }

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        HomeLandscapeArtwork(item: entry.item, width: cardWidth, progress: progress)

        Text(entry.item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(width: cardWidth, alignment: .leading)

        Text("继续 · \(formatTime(entry.lastPosition))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
  }

  private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    let h = value / 3600
    let m = (value % 3600) / 60
    let s = value % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
  }
}

private struct HomeLandscapeArtwork: View {
  let item: CloudItem
  let width: CGFloat
  let progress: Double?

  var body: some View {
    MediaArtworkCard(item: item, progress: progress)
      .frame(width: width)
  }
}

