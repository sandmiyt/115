import SwiftUI

struct FavoritesView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?
  @State private var selectedPhoto: CloudItem?
  @AppStorage("gallery115.compactGrid") private var compactGrid = true
  @AppStorage("gallery115.mediaGridColumns") private var mediaGridColumns = 3
  @State private var scrollPosition: String?
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
          PinchMediaGrid(items: appState.libraryStore.favorites, columnCount: $mediaGridColumns,
                         compact: compactGrid) { item in
            VideoCard(item: item, transitionNamespace: playerTransition, compact: compactGrid) {
              if item.isPhoto { selectedPhoto = item }
              else { selectedVideo = item }
            }
          } footer: {
            Text("\(appState.libraryStore.favorites.count) 个项目")
              .font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
          }
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
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

}
