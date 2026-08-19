import SwiftUI

struct FavoritesView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?

  var body: some View {
    Group {
      if appState.libraryStore.favorites.isEmpty {
        ContentUnavailableView(
          "还没有收藏",
          systemImage: "heart",
          description: Text("长按视频封面即可收藏。")
        )
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(appState.libraryStore.favorites) { item in
              VideoCard(item: item) {
                selectedVideo = item
              }
            }
          }
          .padding(14)
        }
      }
    }
    .navigationTitle("收藏")
    .sheet(item: $selectedVideo) { PlayerScreen(item: $0) }
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: appState.gridColumns)
  }
}
