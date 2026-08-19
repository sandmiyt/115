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

  var body: some View {
    Group {
      if !appState.isConfigured {
        SetupView()
      } else if appState.faceIDEnabled && !appState.isAppUnlocked {
        AppLockView()
      } else {
        MainTabView()
      }
    }
  }
}

private struct AppLockView: View {
  @Environment(AppState.self) private var appState
  @State private var isAuthenticating = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [CinevaTheme.darkBackground, .black],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      VStack(spacing: 24) {
        Spacer()
        CinevaLogoMark(size: 104)

        VStack(spacing: 7) {
          Text("Cineva")
            .font(.system(size: 38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
          Text("私人影音库已锁定")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.58))
        }

        Button {
          guard !isAuthenticating else { return }
          isAuthenticating = true
          Task {
            await appState.authenticateIfNeeded()
            isAuthenticating = false
          }
        } label: {
          HStack(spacing: 10) {
            if isAuthenticating {
              ProgressView().tint(.white)
            } else {
              Image(systemName: "faceid")
            }
            Text("使用\(appState.biometricTitle)解锁")
              .fontWeight(.semibold)
          }
          .frame(maxWidth: .infinity)
          .frame(height: 52)
          .background(CinevaTheme.brandGradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
          .foregroundStyle(.white)
        }
        .padding(.horizontal, 34)

        if let message = appState.biometricErrorMessage {
          Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.60))
            .padding(.horizontal, 36)
        }

        Spacer()
        Label("本机生物识别保护", systemImage: "lock.shield")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.34))
          .padding(.bottom, 22)
      }
    }
    .task {
      guard !isAuthenticating else { return }
      isAuthenticating = true
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
      NavigationStack { HomeView(selectedTab: $selectedTab) }
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
  @Binding var selectedTab: AppTab
  @State private var selectedVideo: CloudItem?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 26) {
        header

        if !appState.libraryStore.recents.isEmpty {
          mediaSection(title: "继续观看", subtitle: "从上次的位置继续") {
            ScrollView(.horizontal) {
              LazyHStack(spacing: 14) {
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

        libraryActions

        if !appState.libraryStore.favorites.isEmpty {
          mediaSection(title: "我的收藏", subtitle: "随时回到喜欢的内容") {
            ScrollView(.horizontal) {
              LazyHStack(spacing: 14) {
                ForEach(appState.libraryStore.favorites.prefix(12)) { item in
                  CompactPosterCard(item: item) {
                    selectedVideo = item
                  }
                }
              }
              .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
          }
        }

        playbackSummary
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
  }

  private var header: some View {
    HStack(spacing: 12) {
      CinevaLogoMark(size: 48)
      VStack(alignment: .leading, spacing: 2) {
        Text("Cineva")
          .font(.system(size: 29, weight: .bold, design: .rounded))
        Text("你的私人云端影院")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) {
        Circle().fill(.green).frame(width: 7, height: 7)
        Text("115 已连接")
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(panelBackground, in: Capsule())
    }
    .padding(.top, 6)
  }

  private var libraryActions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("媒体库")
        .font(.title3.bold())

      HStack(spacing: 12) {
        LibraryActionCard(
          icon: "rectangle.stack.fill",
          title: "浏览资料库",
          subtitle: appState.browserLayout.title,
          accent: CinevaTheme.accent
        ) {
          selectedTab = .library
        }

        LibraryActionCard(
          icon: "clock.arrow.circlepath",
          title: "播放记录",
          subtitle: "\(appState.libraryStore.recents.count) 个项目",
          accent: CinevaTheme.accentWarm
        ) {
          selectedTab = .recent
        }
      }
    }
  }

  private var playbackSummary: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("播放能力")
        .font(.title3.bold())

      HStack(spacing: 0) {
        summaryCell(icon: "4k.tv", title: "原画 / 4K", subtitle: "自动转码")
        Divider().frame(height: 48)
        summaryCell(icon: "captions.bubble", title: "字幕 / 音轨", subtitle: "内嵌切换")
        Divider().frame(height: 48)
        summaryCell(icon: "hand.tap", title: "手势控制", subtitle: "亮度 · 音量")
      }
      .padding(.vertical, 13)
      .background(panelBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
  }

  private func summaryCell(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 5) {
      Image(systemName: icon)
        .font(.headline)
        .foregroundStyle(CinevaTheme.accent)
      Text(title)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
      Text(subtitle)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
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

private struct LibraryActionCard: View {
  @Environment(\.colorScheme) private var colorScheme
  let icon: String
  let title: String
  let subtitle: String
  let accent: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 13) {
        Image(systemName: icon)
          .font(.title3.weight(.semibold))
          .foregroundStyle(accent)
          .frame(width: 38, height: 38)
          .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        colorScheme == .dark ? CinevaTheme.darkPanel : Color(uiColor: .secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )
    }
    .buttonStyle(.plain)
  }
}

private struct ContinueWatchingCard: View {
  let entry: PlaybackEntry
  let action: () -> Void

  private var progress: Double {
    guard entry.item.duration > 0 else { return 0 }
    return min(max(entry.lastPosition / entry.item.duration, 0), 1)
  }

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .bottom) {
          VideoArtwork(item: entry.item)
          GeometryReader { proxy in
            VStack(spacing: 0) {
              Spacer()
              ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.20))
                Rectangle()
                  .fill(CinevaTheme.accent)
                  .frame(width: proxy.size.width * progress)
              }
              .frame(height: 3)
            }
          }
        }
        .frame(width: 214)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        Text(entry.item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(width: 214, alignment: .leading)
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

private struct CompactPosterCard: View {
  let item: CloudItem
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        VideoArtwork(item: item)
          .frame(width: 184)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        Text(item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(width: 184, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
  }
}
