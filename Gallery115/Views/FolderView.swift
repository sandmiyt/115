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
        loadingState
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
        content
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(folderID == appState.rootFolderID ? .large : .inline)
    .navigationDestination(for: CloudItem.self) { item in
      FolderView(folderID: item.id, title: item.name)
    }
    .searchable(text: $query, prompt: "搜索当前目录")
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          appState.browserLayout = appState.browserLayout == .grid ? .list : .grid
        } label: {
          Image(systemName: appState.browserLayout == .grid ? "list.bullet" : "square.grid.2x2")
        }
        .accessibilityLabel(appState.browserLayout == .grid ? "切换列表" : "切换封面墙")

        Menu {
          Section("排序") {
            Picker("排序", selection: $sortMode) {
              ForEach(SortMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
          }

          if appState.browserLayout == .grid {
            Section("封面墙") {
              Picker("每行", selection: gridColumnsBinding) {
                Text("2 列").tag(2)
                Text("3 列").tag(3)
                Text("4 列").tag(4)
              }
            }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
      }
    }
    .fullScreenCover(item: $selectedVideo) { item in
      PlayerScreen(item: item)
    }
    .task(id: folderID) { await load() }
  }

  @ViewBuilder
  private var content: some View {
    switch appState.browserLayout {
    case .grid:
      ScrollView {
        LazyVGrid(columns: columns, spacing: 11) {
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
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 30)
      }
      .refreshable { await load() }

    case .list:
      List {
        ForEach(filteredItems) { item in
          if item.isDirectory {
            NavigationLink(value: item) {
              FolderListRow(item: item)
            }
          } else {
            Button {
              selectedVideo = item
            } label: {
              VideoListRow(item: item)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .listStyle(.plain)
      .refreshable { await load() }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text("正在读取 115…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var gridColumnsBinding: Binding<Int> {
    Binding(
      get: { appState.gridColumns },
      set: { appState.gridColumns = $0 }
    )
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(), spacing: 9, alignment: .top),
      count: appState.gridColumns
    )
  }

  private var filteredItems: [CloudItem] {
    var output = items
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      output = output.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
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
      ZStack(alignment: .bottomLeading) {
        LinearGradient(
          colors: [CinevaTheme.accentWarm.opacity(0.30), CinevaTheme.accent.opacity(0.10)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Image(systemName: "folder.fill")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(CinevaTheme.accent)
          .padding(14)
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text(item.name)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)

      Text("文件夹")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
  }
}

private struct FolderListRow: View {
  let item: CloudItem

  var body: some View {
    HStack(spacing: 13) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(CinevaTheme.accent.opacity(0.10))
        Image(systemName: "folder.fill")
          .font(.title2)
          .foregroundStyle(CinevaTheme.accent)
      }
      .frame(width: 74, height: 52)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.name)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        Text("文件夹")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
    }
    .padding(.vertical, 4)
  }
}

private struct VideoListRow: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem

  var body: some View {
    HStack(spacing: 13) {
      ZStack(alignment: .bottom) {
        VideoArtwork(item: item)
        if progress > 0.002 {
          GeometryReader { proxy in
            VStack(spacing: 0) {
              Spacer()
              ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle()
                  .fill(CinevaTheme.accent)
                  .frame(width: max(2, proxy.size.width * progress))
              }
              .frame(height: 3)
            }
          }
        }
      }
      .frame(width: 82, height: 48)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        Text(item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)

        HStack(spacing: 6) {
          if !item.fileExtension.isEmpty {
            Text(item.fileExtension.uppercased())
          }
          Text(item.formattedSize)
          if !item.formattedDuration.isEmpty {
            Text("·")
            Text(item.formattedDuration)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Image(systemName: "play.circle.fill")
        .font(.title3)
        .foregroundStyle(CinevaTheme.accent)
    }
    .padding(.vertical, 4)
  }

  private var progress: Double {
    guard item.duration > 0 else { return 0 }
    let position = appState.libraryStore.resumePosition(for: item)
    guard position > 2, position < item.duration - 8 else { return 0 }
    return min(max(position / item.duration, 0), 1)
  }
}
