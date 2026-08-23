import SwiftUI

struct FavoritesView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?
  @Namespace private var playerTransition

  var body: some View {
    Group {
      if appState.libraryStore.favorites.isEmpty {
        ContentUnavailableView(
          "还没有收藏",
          systemImage: "heart",
          description: Text("长按视频封面可收藏或取消收藏。")
        )
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(appState.libraryStore.favorites) { item in
              VideoCard(item: item, transitionNamespace: playerTransition) {
                selectedVideo = item
              }
            }
          }
          .id("favorites-grid-\(safeGridColumns)")
          .transaction { transaction in
            transaction.animation = nil
          }
          .padding(14)
        }
      }
    }
    .navigationTitle("收藏")
    .fullScreenCover(item: $selectedVideo) { item in
      PlayerScreen(item: item)
        .cinevaPlayerZoomTransition(sourceID: item.id, in: playerTransition)
    }
  }

  private var safeGridColumns: Int {
    min(max(appState.gridColumns, 2), 4)
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
      count: safeGridColumns
    )
  }
}
