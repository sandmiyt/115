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

  private let pageSize = 56

  @State private var items: [CloudItem] = []
  @State private var isInitialLoading = true
  @State private var isLoadingMore = false
  @State private var errorMessage: String?
  @State private var transientMessage: String?
  @State private var query = ""
  @State private var searchItems: [CloudItem]?
  @State private var displayItems: [CloudItem] = []
  @State private var playlistItems: [CloudItem] = []
  @State private var didScheduleBackgroundRefresh = false
  @State private var sortMode: SortMode = .updated
  @State private var selectedVideo: CloudItem?
  @State private var nextOffset = 0
  @State private var hasMore = true
  @State private var isRefreshing = false
  @State private var showMediaSetup = false

  var body: some View {
    Group {
      if !appState.isConfigured {
        unconfiguredState
      } else if isInitialLoading && items.isEmpty {
        loadingState
      } else if let errorMessage, items.isEmpty {
        ContentUnavailableView {
          Label("读取失败", systemImage: "exclamationmark.triangle")
        } description: {
          Text(errorMessage)
        } actions: {
          Button("重试") { Task { await loadFirstPage(forceRefresh: true) } }
        }
      } else if displayItems.isEmpty {
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
    .onChange(of: query) { _, _ in rebuildDisplayItems() }
    .onChange(of: sortMode) { _, _ in rebuildDisplayItems() }
    .task(id: query) { await updateSearchResults() }
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          Task { await refreshCurrentFolder() }
        } label: {
          if isRefreshing {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "正在刷新资料库" : "刷新资料库")

        Menu {
          Section("视图") {
            Button {
              appState.browserLayout = .grid
            } label: {
              if appState.browserLayout == .grid {
                Label("封面墙", systemImage: "checkmark")
              } else {
                Text("封面墙")
              }
            }
            Button {
              appState.browserLayout = .list
            } label: {
              if appState.browserLayout == .list {
                Label("列表", systemImage: "checkmark")
              } else {
                Text("列表")
              }
            }
          }

          Section("排序") {
            Picker("排序", selection: $sortMode) {
              ForEach(SortMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
          }

          if appState.browserLayout == .grid {
            Section("封面墙") {
              ForEach([2, 3, 4], id: \.self) { count in
                Button {
                  setGridColumnsSafely(count)
                } label: {
                  if safeGridColumns == count {
                    Label("\(count) 列", systemImage: "checkmark")
                  } else {
                    Text("\(count) 列")
                  }
                }
              }
            }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let transientMessage {
        HStack(spacing: 8) {
          Image(systemName: "externaldrive.connected.to.line.below.fill")
          Text(transientMessage).lineLimit(2)
          Spacer(minLength: 4)
          Button("关闭") { self.transientMessage = nil }
            .font(.caption.weight(.semibold))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(.ultraThinMaterial)
      }
    }
    .fullScreenCover(item: $selectedVideo) { item in
      PlayerScreen(item: item, playlist: playlistItems)
    }
    .sheet(isPresented: $showMediaSetup) {
      SetupView()
    }
    .onChange(of: appState.isAppUnlocked) { _, unlocked in
      if !unlocked {
        showMediaSetup = false
      }
    }
    .task(id: "\(folderID)|\(appState.isConfigured)|\(appState.isAppUnlocked)") {
      guard appState.isAppUnlocked else { return }
      if appState.isConfigured {
        await loadFirstPage(forceRefresh: false)
      } else {
        isInitialLoading = false
        isLoadingMore = false
        items = []
        searchItems = nil
        displayItems = []
        playlistItems = []
        errorMessage = nil
      }
    }
  }


  private var unconfiguredState: some View {
    ContentUnavailableView {
      Label("尚未连接媒体源", systemImage: "externaldrive.badge.plus")
    } description: {
      Text("先进入 Cineva，再连接你自己的 OpenList / AList。连接成功后，这里会显示你的 115 媒体库。")
    } actions: {
      Button("连接媒体源") {
        showMediaSetup = true
      }
      .buttonStyle(.borderedProminent)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch appState.browserLayout {
    case .grid:
      ScrollView {
        LazyVGrid(columns: columns, spacing: 11) {
          ForEach(displayItems) { item in
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

          if query.isEmpty, hasMore {
            Color.clear
              .frame(height: 1)
              .onAppear { Task { await loadNextPage() } }
          }

          if isLoadingMore {
            ProgressView()
              .frame(maxWidth: .infinity)
              .padding(.vertical, 18)
          }
        }
        .id("grid-\(folderID)-\(safeGridColumns)")
        .transaction { transaction in
          transaction.animation = nil
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 30)
      }
      .refreshable { await refreshCurrentFolder() }

    case .list:
      List {
        ForEach(displayItems) { item in
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

        if query.isEmpty, hasMore {
          Color.clear
            .frame(height: 1)
            .listRowSeparator(.hidden)
            .onAppear { Task { await loadNextPage() } }
        }

        if isLoadingMore {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .refreshable { await refreshCurrentFolder() }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text("正在读取媒体库…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private var safeGridColumns: Int {
    min(max(appState.gridColumns, 2), 4)
  }

  @MainActor
  private func setGridColumnsSafely(_ value: Int) {
    let clamped = min(max(value, 2), 4)
    guard clamped != safeGridColumns else { return }
    Task { @MainActor in
      // Let the Menu finish its own dismissal transaction before rebuilding
      // LazyVGrid with a different column count. This avoids the SwiftUI
      // re-entrant layout crash seen on physical devices.
      await Task.yield()
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        appState.gridColumns = clamped
      }
    }
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 0), spacing: 9, alignment: .top),
      count: safeGridColumns
    )
  }

  @MainActor
  private func rebuildDisplayItems() {
    let source = searchItems ?? items
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var output = trimmed.isEmpty
      ? source
      : source.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }

    output.sort { lhs, rhs in
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
    displayItems = output

    // Build the queue only when the underlying directory changes instead of
    // sorting the entire video list on every SwiftUI body invalidation.
    playlistItems = source
      .filter { !$0.isDirectory && $0.isVideo }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }


  @MainActor
  private func refreshCurrentFolder() async {
    guard appState.isConfigured, appState.isAppUnlocked, !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    // Keep roughly the same amount of the directory mounted on screen after a
    // refresh. The first forced page makes WebDAVProvider replace its complete
    // directory cache from OpenList; the following pages are sliced from that
    // fresh in-memory snapshot, so additions and removals stay synchronized
    // without throwing away the user's already-loaded scroll range.
    let desiredCount = max(items.count, pageSize)
    var refreshed: [CloudItem] = []
    var offset = 0
    var lastPage: CloudFolderPage?

    do {
      repeat {
        let page = try await appState.api.listFolderPage(
          id: folderID,
          offset: offset,
          limit: pageSize,
          forceRefresh: offset == 0
        )
        lastPage = page
        refreshed.append(contentsOf: page.items)
        offset += page.limit
        if !page.hasMore || refreshed.count >= desiredCount { break }
      } while true

      var known = Set<String>()
      items = refreshed.filter { known.insert($0.id).inserted }
      searchItems = nil
      rebuildDisplayItems()
      nextOffset = offset
      hasMore = lastPage?.hasMore ?? false
      errorMessage = nil

      if lastPage?.servedFromCache == true {
        appState.markMediaUsingCache()
        transientMessage = "媒体服务器暂时不可用，已保留当前资料库缓存。"
      } else {
        appState.markMediaConnected()
        transientMessage = nil
        didScheduleBackgroundRefresh = true
      }

      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await updateSearchResults()
      }
    } catch {
      appState.markMediaOffline()
      transientMessage = "刷新失败，已保留当前资料库。"
    }
  }

  @MainActor
  private func loadFirstPage(forceRefresh: Bool) async {
    isInitialLoading = items.isEmpty
    isLoadingMore = false
    defer { isInitialLoading = false }

    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: 0,
        limit: pageSize,
        forceRefresh: forceRefresh
      )
      items = page.items
      searchItems = nil
      rebuildDisplayItems()
      nextOffset = page.limit
      hasMore = page.hasMore
      errorMessage = nil
      if page.servedFromCache {
        appState.markMediaUsingCache()
        transientMessage = forceRefresh ? "媒体服务器暂时不可用，已继续使用本地资料库缓存。" : nil
        if !forceRefresh, !didScheduleBackgroundRefresh {
          didScheduleBackgroundRefresh = true
          Task { await refreshFirstPageSilently() }
        }
      } else {
        appState.markMediaConnected()
        transientMessage = nil
        didScheduleBackgroundRefresh = true
      }
    } catch {
      appState.markMediaOffline()
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func refreshFirstPageSilently() async {
    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: 0,
        limit: pageSize,
        forceRefresh: true
      )
      items = page.items
      rebuildDisplayItems()
      nextOffset = page.limit
      hasMore = page.hasMore
      if page.servedFromCache {
        appState.markMediaUsingCache()
      } else {
        appState.markMediaConnected()
      }
    } catch {
      // Keep the already rendered cache; a background refresh must never blank the directory.
      appState.markMediaUsingCache()
    }
  }

  @MainActor
  private func updateSearchResults() async {
    guard appState.isAppUnlocked else {
      searchItems = nil
      rebuildDisplayItems()
      return
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchItems = nil
      rebuildDisplayItems()
      return
    }

    try? await Task.sleep(for: .milliseconds(180))
    guard !Task.isCancelled else { return }
    do {
      let all = try await appState.api.listFolder(id: folderID)
      guard !Task.isCancelled else { return }
      searchItems = all
      rebuildDisplayItems()
    } catch {
      // Search the loaded page rather than failing the whole screen.
      searchItems = items
      rebuildDisplayItems()
    }
  }

  @MainActor
  private func loadNextPage() async {
    guard hasMore, !isLoadingMore else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }

    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: nextOffset,
        limit: pageSize,
        forceRefresh: false
      )
      var known = Set(items.map(\.id))
      let additions = page.items.filter { known.insert($0.id).inserted }
      items.append(contentsOf: additions)
      rebuildDisplayItems()
      nextOffset += page.limit
      hasMore = page.hasMore
      if page.servedFromCache {
        appState.markMediaUsingCache()
        transientMessage = "已从本地资料库缓存继续加载。"
      } else {
        appState.markMediaConnected()
      }
    } catch let error as CloudProviderError {
      // Keep the mounted directory visible. The user can continue browsing what has
      // already been indexed instead of losing the whole screen to a temporary 405.
      appState.markMediaOffline()
      transientMessage = error.localizedDescription
    } catch {
      appState.markMediaOffline()
      transientMessage = "网络暂时不可用，已保留当前资料库。"
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
