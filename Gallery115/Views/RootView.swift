import SwiftUI

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
        colors: [Color.black, Color(red: 0.08, green: 0.06, blue: 0.13)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 24) {
        Spacer()

        ZStack {
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.white.opacity(0.08))
            .frame(width: 108, height: 108)
          Image(systemName: "play.rectangle.fill")
            .font(.system(size: 48, weight: .semibold))
            .foregroundStyle(.purple, .white.opacity(0.82))
        }

        VStack(spacing: 8) {
          Text("影")
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
          Text("你的私人影音库")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
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
          .background(.purple, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .foregroundStyle(.white)
        }
        .padding(.horizontal, 34)

        if let message = appState.biometricErrorMessage {
          Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 36)
        }

        Spacer()
        Text("播放记录与 115 授权仅保存在本机")
          .font(.caption)
          .foregroundStyle(.white.opacity(0.35))
          .padding(.bottom, 20)
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
  @Environment(AppState.self) private var appState

  var body: some View {
    TabView {
      NavigationStack {
        HomeView()
      }
      .tabItem { Label("首页", systemImage: "house.fill") }

      NavigationStack {
        FolderView(folderID: appState.rootFolderID, title: "我的文件")
      }
      .tabItem { Label("文件", systemImage: "folder.fill") }

      NavigationStack {
        FavoritesView()
      }
      .tabItem { Label("收藏", systemImage: "heart.fill") }

      NavigationStack {
        RecentView()
      }
      .tabItem { Label("最近", systemImage: "clock.fill") }

      NavigationStack {
        SettingsView()
      }
      .tabItem { Label("设置", systemImage: "gearshape.fill") }
    }
    .toolbarBackground(.visible, for: .tabBar)
  }
}

private struct HomeView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        hero

        if !appState.libraryStore.recents.isEmpty {
          mediaSection(title: "继续观看", subtitle: "接着上次的位置播放") {
            ScrollView(.horizontal) {
              LazyHStack(spacing: 14) {
                ForEach(appState.libraryStore.recents.prefix(12)) { entry in
                  ContinueWatchingCard(entry: entry) {
                    selectedVideo = entry.item
                  }
                }
              }
            }
            .scrollIndicators(.hidden)
          }
        }

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
            }
            .scrollIndicators(.hidden)
          }
        }

        quickInfo
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 28)
    }
    .background(Color(uiColor: .systemBackground))
    .navigationTitle("影")
    .navigationBarTitleDisplayMode(.large)
    .fullScreenCover(item: $selectedVideo) { item in
      PlayerScreen(item: item)
    }
  }

  private var hero: some View {
    ZStack(alignment: .bottomLeading) {
      LinearGradient(
        colors: [Color.purple.opacity(0.75), Color.indigo.opacity(0.48), Color.black.opacity(0.72)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(alignment: .leading, spacing: 8) {
        Image(systemName: "play.rectangle.on.rectangle.fill")
          .font(.system(size: 34, weight: .semibold))
        Text("你的 115，像真正的影音库")
          .font(.title2.bold())
        Text("封面浏览 · 原画/转码播放 · 进度记录")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.72))
      }
      .foregroundStyle(.white)
      .padding(20)
    }
    .frame(height: 176)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 22, y: 10)
  }

  @ViewBuilder
  private func mediaSection<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.title3.bold())
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
      content()
    }
  }

  private var quickInfo: some View {
    HStack(spacing: 12) {
      HomeInfoTile(icon: "heart.fill", value: "\(appState.libraryStore.favorites.count)", label: "收藏")
      HomeInfoTile(icon: "clock.fill", value: "\(appState.libraryStore.recents.count)", label: "最近")
      HomeInfoTile(icon: "rectangle.grid.2x2.fill", value: "\(appState.gridColumns) 列", label: "封面墙")
    }
  }
}

private struct HomeInfoTile: View {
  let icon: String
  let value: String
  let label: String

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Image(systemName: icon)
        .foregroundStyle(.purple)
      Text(value)
        .font(.headline.monospacedDigit())
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

private struct ContinueWatchingCard: View {
  let entry: PlaybackEntry
  let action: () -> Void

  var progress: Double {
    guard entry.item.duration > 0 else { return 0 }
    return min(max(entry.lastPosition / entry.item.duration, 0), 1)
  }

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .bottom) {
          MediaThumbnail(item: entry.item)
          GeometryReader { proxy in
            VStack {
              Spacer()
              ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.22))
                Rectangle()
                  .fill(.purple)
                  .frame(width: proxy.size.width * progress)
              }
              .frame(height: 3)
            }
          }
        }
        .frame(width: 190, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        Text(entry.item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(width: 190, alignment: .leading)
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
        MediaThumbnail(item: item)
          .frame(width: 168, height: 95)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        Text(item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .frame(width: 168, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
  }
}

private struct MediaThumbnail: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  @State private var generatedImage: UIImage?

  var body: some View {
    ZStack {
      Rectangle().fill(.secondary.opacity(0.12))
      if let generatedImage {
        Image(uiImage: generatedImage).resizable().scaledToFill()
      } else if let url = item.thumbnailURL {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFill()
          case .empty: ProgressView()
          default: Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(.secondary)
          }
        }
      } else {
        Image(systemName: "play.rectangle.fill")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
    }
    .clipped()
    .task(id: item.id) {
      if item.thumbnailURL == nil {
        generatedImage = await appState.thumbnailService.generatedThumbnail(for: item, api: appState.api)
      }
    }
  }
}
