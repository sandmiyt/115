import SwiftUI

struct FavoritesView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?
  @State private var selectedPhoto: CloudItem?
  @AppStorage("gallery115.compactGrid") private var compactGrid = true
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
          LazyVGrid(columns: columns, spacing: compactGrid ? 2 : 14) {
            ForEach(appState.libraryStore.favorites) { item in
              VideoCard(item: item, transitionNamespace: playerTransition, compact: compactGrid) {
                if item.isPhoto { selectedPhoto = item }
                else { selectedVideo = item }
              }
            }
          }
          .id("favorites-grid-\(safeGridColumns)")
          .padding(compactGrid ? 2 : 14)
        }
      }
    }
    .navigationTitle("收藏")
    .fullScreenCover(item: $selectedPhoto) { item in
      PhotoPreviewScreen(item: item)
        .cinevaPlayerZoomTransition(sourceID: item.id, in: playerTransition)
    }
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
      repeating: GridItem(.flexible(minimum: 0), spacing: compactGrid ? 2 : 10, alignment: .top),
      count: safeGridColumns
    )
  }
}
