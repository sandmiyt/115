import SwiftUI
import UIKit

struct FolderView: View {
  enum SortMode: String, CaseIterable, Identifiable {
    case updated
    case oldest
    case size
    case sizeAscending
    case name

    var id: String { rawValue }
    var title: String {
      switch self {
      case .updated: return "日期：最新在前"
      case .oldest: return "日期：最旧在前"
      case .name: return "名称：A–Z"
      case .size: return "大小：最大在前"
      case .sizeAscending: return "大小：最小在前"
      }
    }

    var systemImage: String {
      switch self {
      case .updated: return "calendar.badge.clock"
      case .oldest: return "calendar"
      case .name: return "textformat.abc"
      case .size: return "arrow.down.circle"
      case .sizeAscending: return "arrow.up.circle"
      }
    }
  }

  enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos
    case favorites

    var id: String { rawValue }
    var title: String {
      switch self {
      case .all: return "全部"
      case .photos: return "照片"
      case .videos: return "视频"
      case .favorites: return "已收藏"
      }
    }

    var systemImage: String {
      switch self {
      case .all: return "square.grid.2x2"
      case .photos: return "photo"
      case .videos: return "video"
      case .favorites: return "heart.fill"
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
  @State private var displayedFolders: [CloudItem] = []
  @State private var displayedMedia: [CloudItem] = []
  @State private var playlistItems: [CloudItem] = []
  @State private var didScheduleBackgroundRefresh = false
  @State private var sortMode: SortMode = .updated
  @State private var mediaFilter: MediaFilter = .all
  @State private var selectedVideo: CloudItem?
  @State private var nextOffset = 0
  @State private var hasMore = true
  @State private var isRefreshing = false
  @State private var refreshTask: Task<Void, Never>?
  @State private var pagingRevision = 0
  @State private var showMediaSetup = false
  @AppStorage("gallery115.compactGrid") private var compactGrid = true
  @AppStorage("gallery115.mediaGridColumns") private var mediaGridColumns = 3
  @State private var loadedFolderScope: String?
  @State private var artworkRefreshRevision = 0
  @State private var isSearching = false
  @State private var selectedPhoto: CloudItem?
  @Namespace private var playerTransition

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
      } else if displayItems.isEmpty && !isSearching && (!query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasMore) {
        ContentUnavailableView(
          query.isEmpty ? emptyFilterTitle : "没有搜索结果",
          systemImage: query.isEmpty ? emptyFilterSystemImage : "magnifyingglass",
          description: Text(query.isEmpty ? emptyFilterDescription : "换一个关键词试试。")
        )
      } else {
        content
      }
    }
    .environment(\.artworkRefreshRevision, artworkRefreshRevision)
    .onDisappear { refreshTask?.cancel(); refreshTask = nil }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(folderID == appState.rootFolderID ? .large : .inline)
    .navigationDestination(for: CloudItem.self) { item in
      FolderView(folderID: item.id, title: item.name)
    }
    .searchable(text: $query, prompt: "搜索当前目录")
    .onChange(of: query) { _, _ in
      searchItems = nil
      isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      rebuildDisplayItems()
    }
    .onChange(of: mediaFilter) { _, _ in rebuildDisplayItems() }
    .sensoryFeedback(.selection, trigger: mediaFilter)
    .onChange(of: appState.libraryStore.favorites.map(\.id)) { _, _ in rebuildDisplayItems() }
    .task(id: "\(query)|\(sortMode.rawValue)") { await updateSearchResults() }
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Menu {
            Picker("筛选", selection: $mediaFilter) {
              ForEach(MediaFilter.allCases) { filter in
                Label(filter.title, systemImage: filter.systemImage)
                  .tag(filter)
              }
            }
          } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease")
          }

          Menu {
            Picker("排序", selection: $sortMode) {
              ForEach(SortMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                  .tag(mode)
              }
            }
          } label: {
            Label("排序", systemImage: "arrow.up.arrow.down")
          }

          Divider()

          Menu {
            Toggle("相册式方形网格", isOn: $compactGrid)
            Divider()
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

            if appState.browserLayout == .grid {
              Divider()
              Picker("媒体缩略图大小", selection: $mediaGridColumns) {
                ForEach(MediaGridZoomPolicy.levels, id: \.self) { count in
                  Text("\(count) 列").tag(count)
                }
              }
              Divider()
              ForEach([2, 3, 4], id: \.self) { count in
                Button {
                  setGridColumnsSafely(count)
                } label: {
                  if safeGridColumns == count {
                    Label("文件夹 \(count) 列", systemImage: "checkmark")
                  } else {
                    Text("文件夹 \(count) 列")
                  }
                }
              }
            }
          } label: {
            Label("显示", systemImage: appState.browserLayout == .grid ? "square.grid.2x2" : "list.bullet")
          }
        } label: {
          Image(
            systemName: mediaFilter == .all && sortMode == .updated
              ? "line.3.horizontal.decrease.circle"
              : "line.3.horizontal.decrease.circle.fill"
          )
        }
        .accessibilityLabel("筛选与排序")
        .accessibilityValue("\(mediaFilter.title)，\(sortMode.title)")

        Button {
          guard !isRefreshing else { return }
          refreshTask?.cancel()
          refreshTask = Task { await refreshCurrentFolder() }
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
        .accessibilityHint("重新读取新增或删除的媒体")
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if appState.isConfigured {
        Picker("媒体类型", selection: $mediaFilter) {
          ForEach(MediaFilter.allCases) { filter in Text(filter.title).tag(filter) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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
        .cinevaPlayerZoomTransition(sourceID: item.id, in: playerTransition)
    }
    .fullScreenCover(item: $selectedPhoto) { item in
      PhotoPreviewScreen(item: item)
        .cinevaPlayerZoomTransition(sourceID: item.id, in: playerTransition)
    }
    .sheet(isPresented: $showMediaSetup) {
      SetupView()
    }
    .onChange(of: appState.isAppUnlocked) { _, unlocked in
      if !unlocked {
        showMediaSetup = false
      }
    }
    .task(id: "\(appState.mediaSourceRevision)|\(folderID)|\(appState.isConfigured)|\(appState.isAppUnlocked)|\(sortMode.rawValue)") {
      guard appState.isAppUnlocked else { return }
      if appState.isConfigured {
        await loadFirstPage(forceRefresh: false)
      } else {
        isInitialLoading = false
        isLoadingMore = false
        items = []
        searchItems = nil
        displayItems = []
        displayedFolders = []
        displayedMedia = []
        playlistItems = []
        errorMessage = nil
      }
    }
    .task(id: thumbnailPrefetchSignature, priority: .utility) {
      guard appState.isConfigured, appState.isAppUnlocked, !thumbnailPrefetchSignature.isEmpty else {
        return
      }
      await appState.thumbnailService.prefetch(displayItems, api: appState.api, limit: 12)
    }
  }


  private var unconfiguredState: some View {
    ContentUnavailableView {
      Label("尚未连接媒体源", systemImage: "externaldrive.badge.plus")
    } description: {
      Text("可使用 115 官方授权直接连接，也可以继续使用自己的 OpenList / AList。")
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
      StableLibraryScrollView(itemIDs: Set(displayItems.map(\.id)),
                              resetKey: "\(appState.mediaSourceRevision)|\(folderID)|\(sortMode.rawValue)") {
        VStack(spacing: 14) {
          if !displayedFolders.isEmpty {
            LazyVGrid(columns: columns, spacing: 11) {
              ForEach(displayedFolders) { item in
                NavigationLink(value: item) { FolderCard(item: item) }
                  .buttonStyle(FolderCardButtonStyle())
              }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 10)
            .padding(.top, 10)
          }
          PinchMediaGrid(items: displayedMedia, columnCount: $mediaGridColumns, compact: compactGrid) { item in
            VideoCard(item: item, transitionNamespace: playerTransition, compact: compactGrid) {
              if item.isPhoto { selectedPhoto = item }
              else { selectedVideo = item }
            }
          } footer: {
            paginationFooter.padding(.vertical, 20)
          }
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .refreshable { await refreshCurrentFolder() }

    case .list:
      List {
        ForEach(displayItems) { item in
          if item.isDirectory {
            NavigationLink(value: item) {
              FolderListRow(item: item)
            }
          } else if item.isPhoto {
            Button { selectedPhoto = item } label: {
              PhotoListRow(item: item)
                .cinevaPlayerTransitionSource(id: item.id, in: playerTransition)
            }
            .buttonStyle(.plain)
          } else {
            Button {
              selectedVideo = item
            } label: {
              VideoListRow(item: item)
                .cinevaPlayerTransitionSource(id: item.id, in: playerTransition)
            }
            .buttonStyle(.plain)
            .contextMenu {
              favoriteMenuButton(for: item)
            }
          }
        }

        paginationFooter
          .listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .scrollDismissesKeyboard(.interactively)
      .refreshable { await refreshCurrentFolder() }
    }
  }

  @ViewBuilder
  private var paginationFooter: some View {
    if isSearching {
      ProgressView("正在搜索…").font(.caption)
    } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasMore {
      if let transientMessage, !isLoadingMore {
        Button("继续加载") { Task { await loadNextPage() } }
          .accessibilityHint(transientMessage)
      } else {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity, minHeight: 36)
          .task(id: "\(pagingRevision)|\(nextOffset)|\(mediaFilter.rawValue)|\(isInitialLoading)|\(isRefreshing)") {
            await loadNextPage()
          }
      }
    } else if !displayItems.isEmpty {
      Text("\(displayItems.count) 个项目")
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
  }

  private var thumbnailPrefetchSignature: String {
    displayItems.lazy
      .filter(\.isVideo)
      .prefix(12)
      .map { "\($0.id):\($0.size)" }
      .joined(separator: "|")
  }

  private var emptyFilterTitle: String {
    switch mediaFilter {
    case .all: return "这里没有媒体"
    case .photos: return "这里没有照片"
    case .videos: return "这里没有视频"
    case .favorites: return "这里没有已收藏内容"
    }
  }

  private var emptyFilterSystemImage: String {
    switch mediaFilter {
    case .all: return "rectangle.stack"
    case .photos: return "photo.on.rectangle.angled"
    case .videos: return "video.slash"
    case .favorites: return "heart.slash"
    }
  }

  private var emptyFilterDescription: String {
    switch mediaFilter {
    case .all: return "当前目录中没有文件夹或视频。"
    case .photos: return "当前目录中没有可显示的照片。"
    case .videos: return "当前目录中没有视频。"
    case .favorites: return "当前目录中没有已收藏的媒体。"
    }
  }

  @ViewBuilder
  private func favoriteMenuButton(for item: CloudItem) -> some View {
    let isFavorite = appState.libraryStore.isFavorite(item)
    Button {
      toggleFavoriteWithFeedback(item)
    } label: {
      Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "heart.slash" : "heart")
    }
  }

  @MainActor
  private func toggleFavoriteWithFeedback(_ item: CloudItem) {
    appState.libraryStore.toggleFavorite(item)
    let feedback = UIImpactFeedbackGenerator(style: .medium)
    feedback.prepare()
    feedback.impactOccurred(intensity: 0.82)
    rebuildDisplayItems()
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

    switch mediaFilter {
    case .all:
      // Preserve Cineva's existing default library exactly: folders + videos.
      // Photos are surfaced only when the user explicitly asks for them.
      output = output.filter { $0.isDirectory || $0.isVideo }
    case .photos:
      output = output.filter { $0.isDirectory || $0.isPhoto }
    case .videos:
      output = output.filter { $0.isDirectory || $0.isVideo }
    case .favorites:
      output = output.filter { !$0.isDirectory && appState.libraryStore.isFavorite($0) }
    }

    displayItems = output
    displayedFolders = output.filter(\.isDirectory)
    displayedMedia = output.filter { !$0.isDirectory }
  }

  private func rebuildPlaylistItems() {
    playlistItems = items
      .filter { !$0.isDirectory && $0.isVideo }
      .sorted {
        let comparison = $0.name.localizedStandardCompare($1.name)
        return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
      }
  }

  private var collectionSortOrder: CloudItemSortOrder {
    switch sortMode {
    case .updated: return .updated
    case .oldest: return .oldest
    case .name: return .name
    case .size: return .size
    case .sizeAscending: return .sizeAscending
    }
  }


  @MainActor
  private func refreshCurrentFolder() async {
    guard appState.isConfigured, appState.isAppUnlocked, !isRefreshing else { return }
    pagingRevision &+= 1
    let revision = pagingRevision
    isLoadingMore = false
    isRefreshing = true
    defer { if revision == pagingRevision { isRefreshing = false } }

    // Manual refresh means a real directory synchronization, not just a repaint
    // of the currently visible page. The first forced page invalidates both
    // OpenList's storage cache and Cineva's WebDAV caches; the following slices
    // come from that fresh snapshot. Reading every slice guarantees a new file
    // is visible even when its name would sort beyond the pages already loaded,
    // and guarantees remote deletions disappear immediately.
    var refreshed: [CloudItem] = []
    var offset = 0
    var lastPage: CloudFolderPage?

    do {
      repeat {
        guard revision == pagingRevision, !Task.isCancelled else { return }
        let page = try await appState.api.listFolderPage(
          id: folderID,
          offset: offset,
          limit: pageSize,
          forceRefresh: offset == 0,
          sortOrder: collectionSortOrder
        )
        lastPage = page
        refreshed.append(contentsOf: page.items)
        offset += page.limit
        if !page.hasMore { break }
      } while true

      guard revision == pagingRevision, !Task.isCancelled else { return }

      artworkRefreshRevision &+= 1
      items = CloudItemCollectionPolicy.ordered(refreshed, by: collectionSortOrder)
      searchItems = nil
      rebuildDisplayItems()
      rebuildPlaylistItems()
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
      guard !Task.isCancelled, revision == pagingRevision else { return }
      appState.markMediaOffline()
      transientMessage = "刷新失败，已保留当前资料库。"
    }
  }

  @MainActor
  private func loadFirstPage(forceRefresh: Bool) async {
    let scope = "\(appState.mediaSourceRevision)|\(folderID)|\(sortMode.rawValue)"
    // SwiftUI restarts screen tasks on tab/navigation return. Do not truncate a
    // populated directory while its scroll position still points at a later page.
    if !forceRefresh, loadedFolderScope == scope, !items.isEmpty { return }
    if loadedFolderScope != scope {
      items = []
      searchItems = nil
      rebuildDisplayItems()
      playlistItems = []
      nextOffset = 0
      hasMore = true
      didScheduleBackgroundRefresh = false
    }
    pagingRevision &+= 1
    let revision = pagingRevision
    isInitialLoading = items.isEmpty
    isLoadingMore = false
    isRefreshing = false
    defer { if revision == pagingRevision { isInitialLoading = false } }

    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: 0,
        limit: pageSize,
        forceRefresh: forceRefresh,
        sortOrder: collectionSortOrder
      )
      guard revision == pagingRevision, !Task.isCancelled else { return }
      loadedFolderScope = scope
      isInitialLoading = false
      items = CloudItemCollectionPolicy.ordered(page.items, by: collectionSortOrder)
      searchItems = nil
      rebuildDisplayItems()
      rebuildPlaylistItems()
      nextOffset = page.limit
      hasMore = page.hasMore
      errorMessage = nil
      if page.servedFromCache {
        appState.markMediaUsingCache()
        transientMessage = forceRefresh ? "媒体服务器暂时不可用，已继续使用本地资料库缓存。" : nil
        if !forceRefresh, !didScheduleBackgroundRefresh {
          didScheduleBackgroundRefresh = true
          // Keep this refresh as a child of the screen task so leaving/changing
          // folders cancels its network work and prevents late state mutation.
          await refreshFirstPageSilently()
        }
      } else {
        appState.markMediaConnected()
        transientMessage = nil
        didScheduleBackgroundRefresh = true
      }
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Task.isCancelled {
        await updateSearchResults()
      }
    } catch {
      guard !Task.isCancelled, revision == pagingRevision else { return }
      appState.markMediaOffline()
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func refreshFirstPageSilently() async {
    let revision = pagingRevision
    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: 0,
        limit: pageSize,
        forceRefresh: true,
        sortOrder: collectionSortOrder
      )
      guard !Task.isCancelled, revision == pagingRevision else { return }
      artworkRefreshRevision &+= 1
      items = CloudItemCollectionPolicy.mergingFirstPage(
        page.items,
        into: items,
        by: collectionSortOrder
      )
      rebuildDisplayItems()
      rebuildPlaylistItems()
      nextOffset = max(nextOffset, page.offset + page.limit)
      if let total = page.total {
        hasMore = nextOffset < total
      } else {
        hasMore = hasMore || page.hasMore
      }
      if page.servedFromCache {
        appState.markMediaUsingCache()
      } else {
        appState.markMediaConnected()
      }
    } catch {
      guard !Task.isCancelled, revision == pagingRevision else { return }
      // Keep the already rendered cache; a background refresh must never blank the directory.
      appState.markMediaUsingCache()
    }
  }

  @MainActor
  private func updateSearchResults() async {
    guard appState.isAppUnlocked else {
      isSearching = false
      searchItems = nil
      rebuildDisplayItems()
      return
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      isSearching = false
      searchItems = nil
      rebuildDisplayItems()
      return
    }

    let revision = pagingRevision
    isSearching = true
    defer {
      if !Task.isCancelled, revision == pagingRevision,
        trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) { isSearching = false }
    }
    try? await Task.sleep(for: .milliseconds(180))
    guard !Task.isCancelled, revision == pagingRevision,
        trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    do {
      let all = try await appState.api.listFolder(id: folderID)
      guard !Task.isCancelled, revision == pagingRevision,
        trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
      searchItems = CloudItemCollectionPolicy.ordered(all, by: collectionSortOrder)
      rebuildDisplayItems()
    } catch {
      guard !Task.isCancelled, revision == pagingRevision,
        trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
      // Search the loaded page rather than failing the whole screen.
      searchItems = items
      rebuildDisplayItems()
    }
  }

  @MainActor
  private func loadNextPage() async {
    guard hasMore, !isLoadingMore, !isRefreshing, !isInitialLoading,
      appState.isAppUnlocked, appState.isConfigured, !Task.isCancelled else { return }
    let requestedOffset = nextOffset
    let revision = pagingRevision
    isLoadingMore = true
    transientMessage = nil
    defer { if revision == pagingRevision { isLoadingMore = false } }

    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: requestedOffset,
        limit: pageSize,
        forceRefresh: false,
        sortOrder: collectionSortOrder
      )
      guard revision == pagingRevision, requestedOffset == nextOffset, !Task.isCancelled else { return }
      items = CloudItemCollectionPolicy.appendingPage(
        page.items,
        to: items,
        by: collectionSortOrder
      )
      rebuildDisplayItems()
      rebuildPlaylistItems()
      nextOffset = requestedOffset + page.limit
      hasMore = page.hasMore
      if page.servedFromCache {
        appState.markMediaUsingCache()
        // Cached pagination is an expected fast path. Showing a safe-area banner
        // here changes the viewport height while the user is scrolling and can
        // itself look like a backwards jump.
      } else {
        appState.markMediaConnected()
      }
    } catch let error as CloudProviderError {
      guard !Task.isCancelled, revision == pagingRevision else { return }
      // Keep the mounted directory visible. The user can continue browsing what has
      // already been indexed instead of losing the whole screen to a temporary 405.
      appState.markMediaOffline()
      transientMessage = error.localizedDescription
    } catch {
      guard !Task.isCancelled, revision == pagingRevision else { return }
      appState.markMediaOffline()
      transientMessage = "网络暂时不可用，已保留当前资料库。"
    }
  }
}

private struct FolderCardButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
      .opacity(configuration.isPressed ? 0.90 : 1)
      .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
  }
}

private struct FolderCard: View {
  let item: CloudItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .bottomLeading) {
        LinearGradient(
          colors: [CinevaTheme.accentWarm.opacity(0.30), CinevaTheme.accent.opacity(0.10)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
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

private struct PhotoListRow: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem

  var body: some View {
    HStack(spacing: 13) {
      VideoArtwork(item: item)
        .frame(width: 82, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        Text(item.name)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
        HStack(spacing: 6) {
          if !item.fileExtension.isEmpty { Text(item.fileExtension.uppercased()) }
          Text(item.formattedSize)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      if appState.libraryStore.isFavorite(item) {
        Image(systemName: "heart.fill")
          .foregroundStyle(CinevaTheme.accent)
      } else {
        Image(systemName: "photo")
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .contextMenu {
      let isFavorite = appState.libraryStore.isFavorite(item)
      Button {
        appState.libraryStore.toggleFavorite(item)
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.82)
      } label: {
        Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "heart.slash" : "heart")
      }
    }
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
    let duration = appState.libraryStore.knownDuration(for: item)
    guard duration > 0 else { return 0 }
    let position = appState.libraryStore.resumePosition(for: item)
    guard position > 2, position < duration - 8 else { return 0 }
    return min(max(position / duration, 0), 1)
  }
}

/// Scroll position changes must not re-evaluate the folder's menus, filters and
/// media cell builder for every row crossed during a drag.
private struct StableLibraryScrollView<Content: View>: View {
  let itemIDs: Set<String>
  let resetKey: String
  let content: Content
  @State private var position: String?

  init(itemIDs: Set<String>, resetKey: String, @ViewBuilder content: () -> Content) {
    self.itemIDs = itemIDs
    self.resetKey = resetKey
    self.content = content()
  }

  var body: some View {
    ScrollView { content }
      .scrollPosition(id: $position, anchor: .top)
      .onChange(of: itemIDs) { _, ids in
        if let position, !ids.contains(position) { self.position = nil }
      }
      .onChange(of: resetKey) { _, _ in position = nil }
  }
}
