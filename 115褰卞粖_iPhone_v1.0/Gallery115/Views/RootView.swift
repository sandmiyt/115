import SwiftUI

struct RootView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    Group {
      if appState.isConfigured {
        MainTabView()
      } else {
        SetupView()
      }
    }
  }
}

private struct MainTabView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    TabView {
      NavigationStack {
        FolderView(folderID: appState.rootFolderID, title: "115")
      }
      .tabItem { Label("文件", systemImage: "folder") }

      NavigationStack {
        FavoritesView()
      }
      .tabItem { Label("收藏", systemImage: "heart") }

      NavigationStack {
        RecentView()
      }
      .tabItem { Label("最近", systemImage: "clock") }

      NavigationStack {
        SettingsView()
      }
      .tabItem { Label("设置", systemImage: "gearshape") }
    }
  }
}
