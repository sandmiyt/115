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
  @State private var launchHeroProgress: CGFloat = 0
  @State private var launchHeroVisible = true
  @State private var launchHeroStarted = false

  private var isPrivacyLocked: Bool {
    appState.faceIDEnabled && !appState.isAppUnlocked
  }

  var body: some View {
    ZStack {
      // Keep the main hierarchy alive while locked so returning from the
      // background does not reset the selected tab, navigation stack, or an
      // active full-screen player. Sensitive content is heavily blurred and
      // cannot receive touches until biometric authentication succeeds.
      MainTabView()
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
        LaunchHeroOverlay(destination: homeLogoFrame, progress: launchHeroProgress)
          .allowsHitTesting(true)
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
        withAnimation(.easeOut(duration: 0.22)) { launchHeroProgress = 1 }
        try? await Task.sleep(for: .milliseconds(240))
      } else {
        withAnimation(.spring(response: 0.72, dampingFraction: 0.88, blendDuration: 0.16)) {
          launchHeroProgress = 1
        }
        try? await Task.sleep(for: .milliseconds(780))
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
  let progress: CGFloat

  var body: some View {
    GeometryReader { proxy in
      let startCenter = CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
      let endCenter = CGPoint(x: destination.midX, y: destination.midY)
      let p = min(max(progress, 0), 1)
      let center = CGPoint(
        x: startCenter.x + (endCenter.x - startCenter.x) * p,
        y: startCenter.y + (endCenter.y - startCenter.y) * p
      )
      let destinationSize = max(destination.width, 48)
      let logoSize = 120 + (destinationSize - 120) * p
      let backgroundOpacity = max(0, 1 - p * 1.18)
      let logoOpacity = p < 0.84 ? 1 : max(0, 1 - (p - 0.84) / 0.16)

      ZStack {
        Color(uiColor: .systemBackground)
          .opacity(backgroundOpacity)
          .ignoresSafeArea()

        // The runtime overlay uses the exact same asset as UILaunchScreen. At
        // the final few frames it crossfades into the existing Home logo, so
        // the Home UI itself does not need to change.
        Image("LaunchLogo")
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: logoSize, height: logoSize)
          .position(center)
          .opacity(logoOpacity)
          .shadow(color: .black.opacity(0.10 * (1 - p)), radius: 14 * (1 - p), y: 6 * (1 - p))
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .ignoresSafeArea()
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

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack { HomeView() }
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

