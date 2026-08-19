import SwiftUI

struct FolderView: View {
  enum SortMode: String, CaseIterable, Identifiable {
    case updated
    case name
    case size

    var id: String { rawValue }
    var title: String {
      switch self {
      case .updated: return "最近更新"
      case .name: return "名称"
      case .size: return "大小"
      }
    }
  }

  @Environment(AppState.self) private var appState
  let folderID: String
  let title: String

  @State private var items: [CloudItem] = []
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var query = ""
  @State private var sortMode: SortMode = .updated
  @State private var selectedVideo: CloudItem?

  var body: some View {
    Group {
      if isLoading && items.isEmpty {
        ProgressView("正在读取 115…")
      } else if let errorMessage, items.isEmpty {
        ContentUnavailableView {
          Label("读取失败", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("重试") { Task { await load() } }
        }
      } else if filteredItems.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "这里没有视频" : "没有搜索结果",
          systemImage: query.isEmpty ? "video.slash" : "magnifyingglass",
          description: Text(query.isEmpty ? "当前目录中没有文件夹或视频。" : "换一个关键词试试。")
        )
      } else {
        ScrollView {
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(filteredItems) { item in
              if item.isDirectory {
                NavigationLink(value: item) {
                  FolderCard(item: item)
                }
                .buttonStyle(.plain)
              } else {
                VideoCard(item: item) {
                  selectedVideo = item
                }
              }
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
        }
        .refreshable { await load() }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(for: CloudItem.self) { item in
      FolderView(folderID: item.id, title: item.name)
    }
    .searchable(text: $query, prompt: "搜索当前目录")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Picker("排序", selection: $sortMode) {
            ForEach(SortMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          Divider()
          Picker("每行", selection: gridColumnsBinding) {
            Text("2 列").tag(2)
            Text("3 列").tag(3)
            Text("4 列").tag(4)
          }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
      }
    }
    .sheet(item: $selectedVideo) { item in
      PlayerScreen(item: item)
    }
    .task(id: folderID) { await load() }
  }

  private var gridColumnsBinding: Binding<Int> {
    Binding(
      get: { appState.gridColumns },
      set: { appState.gridColumns = $0 }
    )
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
      count: appState.gridColumns
    )
  }

  private var filteredItems: [CloudItem] {
    var output = items
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      output = output.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    return output.sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
      switch sortMode {
      case .updated:
        return lhs.modifiedAt > rhs.modifiedAt
      case .name:
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      case .size:
        return lhs.size > rhs.size
      }
    }
  }

  @MainActor
  private func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      items = try await appState.api.listFolder(id: folderID)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct FolderCard: View {
  let item: CloudItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 14)
          .fill(.quaternary)
        Image(systemName: "folder.fill")
          .font(.system(size: 34))
          .foregroundStyle(.tint)
      }
      .aspectRatio(16 / 10, contentMode: .fit)

      Text(item.name)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
    .contentShape(Rectangle())
  }
}
