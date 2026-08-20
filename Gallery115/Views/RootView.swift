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

  private var isPrivacyLocked: Bool {
    appState.faceIDEnabled && !appState.isAppUnlocked
  }

  var body: some View {
    ZStack {
      if isPrivacyLocked {
        LockedPrivacyBackground()
      } else {
        MainTabView()
      }

      if isPrivacyLocked {
        AppLockView()
          .zIndex(10_000)
      }
    }
    .animation(.easeOut(duration: 0.16), value: isPrivacyLocked)
  }
}

private struct LockedPrivacyBackground: View {
  var body: some View {
    ZStack {
      Color.black
      LinearGradient(
        colors: [
          CinevaTheme.accent.opacity(0.20),
          Color.black,
          CinevaTheme.accentRed.opacity(0.12),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .blur(radius: 34)
      .scaleEffect(1.15)
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
      .task {
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
    .task {
      guard !didCheckConnection, appState.isConfigured else { return }
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

