import SwiftUI

struct FavoritesView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?
  @State private var selectedPhoto: CloudItem?
  @AppStorage("gallery115.compactGrid") private var compactGrid = true
  @AppStorage("gallery115.mediaGridColumns") private var mediaGridColumns = 3
  @State private var scrollPosition: String?
  @State private var isSelecting = false
  @State private var selectedIDs = Set<String>()
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
            VideoCard(item: item, transitionNamespace: playerTransition, compact: compactGrid,
                      selectionMode: isSelecting, isSelected: selectedIDs.contains(item.id)) {
              if isSelecting {
                guard item.isVideo else { return }
                if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                return
              }
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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(isSelecting ? "完成" : "选择") {
          isSelecting.toggle()
          selectedIDs.removeAll()
        }
        .disabled(appState.libraryStore.favorites.isEmpty)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if isSelecting {
        MediaSelectionBar(count: selectedIDs.count, onSelectAll: {
          selectedIDs = Set(appState.libraryStore.favorites.filter(\.isVideo).map(\.id))
        }, onDone: { isSelecting = false; selectedIDs.removeAll() }, onFavorite: nil, onUnfavorite: {
          let selected = appState.libraryStore.favorites.filter { selectedIDs.contains($0.id) }
          appState.libraryStore.setFavorites(selected, enabled: false)
          selectedIDs.removeAll()
          isSelecting = false
        })
      }
    }
    .onChange(of: appState.libraryStore.favorites.map(\.id)) { _, ids in
      selectedIDs.formIntersection(Set(ids))
      if let scrollPosition, !ids.contains(scrollPosition) { self.scrollPosition = nil }
      if ids.isEmpty { isSelecting = false }
    }
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
