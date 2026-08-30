import SwiftUI
import UIKit

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
  @State private var playlistItems: [CloudItem] = []
  @State private var didScheduleBackgroundRefresh = false
  @State private var sortMode: SortMode = .updated
  @State private var mediaFilter: MediaFilter = .all
  @State private var selectedVideo: CloudItem?
  @State private var nextOffset = 0
  @State private var hasMore = true
  @State private var isRefreshing = false
  @State private var pagingRevision = 0
  @State private var showMediaSetup = false
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
      } else if displayItems.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? emptyFilterTitle : "没有搜索结果",
          systemImage: query.isEmpty ? emptyFilterSystemImage : "magnifyingglass",
          description: Text(query.isEmpty ? emptyFilterDescription : "换一个关键词试试。")
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
    .onChange(of: sortMode) { _, _ in
      items = CloudItemCollectionPolicy.ordered(items, by: collectionSortOrder)
      if let searchItems {
        self.searchItems = CloudItemCollectionPolicy.ordered(searchItems, by: collectionSortOrder)
      }
      rebuildDisplayItems()
    }
    .onChange(of: mediaFilter) { _, _ in rebuildDisplayItems() }
    .onChange(of: appState.libraryStore.favorites.map(\.id)) { _, _ in rebuildDisplayItems() }
    .task(id: query) { await updateSearchResults() }
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Menu {
          Picker("筛选", selection: $mediaFilter) {
            ForEach(MediaFilter.allCases) { filter in
              Label(filter.title, systemImage: filter.systemImage)
                .tag(filter)
            }
          }
        } label: {
          Image(systemName: mediaFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("筛选资料库")
        .accessibilityValue(mediaFilter.title)

        // Refresh keeps its established position and behavior. The menu behind
        // a long press still contains the existing view/sort controls.
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
          if isRefreshing {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        } primaryAction: {
          guard !isRefreshing else { return }
          Task { await refreshCurrentFolder() }
        }
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? "正在刷新资料库" : "刷新资料库")
        .accessibilityHint("轻点立即刷新；长按可调整视图和排序")
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
              .buttonStyle(FolderCardButtonStyle())
            } else if item.isPhoto {
              PhotoFileCard(item: item)
            } else {
              VideoCard(item: item, transitionNamespace: playerTransition) {
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
          } else if item.isPhoto {
            PhotoListRow(item: item)
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

  private var thumbnailPrefetchSignature: String {
    displayItems.lazy
      .filter(\.isVideo)
      .prefix(12)
      .map { "\($0.id):\($0.sha1)" }
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

    // Build the queue only when the underlying directory changes instead of
    // sorting the entire video list on every SwiftUI body invalidation.
    playlistItems = source
      .filter { !$0.isDirectory && $0.isVideo }
      .sorted {
        let comparison = $0.name.localizedStandardCompare($1.name)
        return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
      }
  }

  private var collectionSortOrder: CloudItemSortOrder {
    switch sortMode {
    case .updated: return .updated
    case .name: return .name
    case .size: return .size
    }
  }


  @MainActor
  private func refreshCurrentFolder() async {
    guard appState.isConfigured, appState.isAppUnlocked, !isRefreshing else { return }
    pagingRevision &+= 1
    let revision = pagingRevision
    isLoadingMore = false
    isRefreshing = true
    defer { isRefreshing = false }

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
        let page = try await appState.api.listFolderPage(
          id: folderID,
          offset: offset,
          limit: pageSize,
          forceRefresh: offset == 0
        )
        lastPage = page
        refreshed.append(contentsOf: page.items)
        offset += page.limit
        if !page.hasMore { break }
      } while true

      guard revision == pagingRevision, !Task.isCancelled else { return }

      items = CloudItemCollectionPolicy.ordered(refreshed, by: collectionSortOrder)
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
      guard !Task.isCancelled else { return }
      appState.markMediaOffline()
      transientMessage = "刷新失败，已保留当前资料库。"
    }
  }

  @MainActor
  private func loadFirstPage(forceRefresh: Bool) async {
    pagingRevision &+= 1
    let revision = pagingRevision
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
      guard revision == pagingRevision, !Task.isCancelled else { return }
      items = CloudItemCollectionPolicy.ordered(page.items, by: collectionSortOrder)
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
          // Keep this refresh as a child of the screen task so leaving/changing
          // folders cancels its network work and prevents late state mutation.
          await refreshFirstPageSilently()
        }
      } else {
        appState.markMediaConnected()
        transientMessage = nil
        didScheduleBackgroundRefresh = true
      }
    } catch {
      guard !Task.isCancelled else { return }
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
      guard !Task.isCancelled else { return }
      items = CloudItemCollectionPolicy.mergingFirstPage(
        page.items,
        into: items,
        by: collectionSortOrder
      )
      rebuildDisplayItems()
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
      guard !Task.isCancelled else { return }
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
      searchItems = CloudItemCollectionPolicy.ordered(all, by: collectionSortOrder)
      rebuildDisplayItems()
    } catch {
      guard !Task.isCancelled else { return }
      // Search the loaded page rather than failing the whole screen.
      searchItems = items
      rebuildDisplayItems()
    }
  }

  @MainActor
  private func loadNextPage() async {
    guard hasMore, !isLoadingMore else { return }
    let requestedOffset = nextOffset
    let revision = pagingRevision
    isLoadingMore = true
    defer { isLoadingMore = false }

    do {
      let page = try await appState.api.listFolderPage(
        id: folderID,
        offset: requestedOffset,
        limit: pageSize,
        forceRefresh: false
      )
      guard revision == pagingRevision, requestedOffset == nextOffset, !Task.isCancelled else { return }
      items = CloudItemCollectionPolicy.appendingPage(
        page.items,
        to: items,
        by: collectionSortOrder
      )
      rebuildDisplayItems()
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
      guard !Task.isCancelled else { return }
      // Keep the mounted directory visible. The user can continue browsing what has
      // already been indexed instead of losing the whole screen to a temporary 405.
      appState.markMediaOffline()
      transientMessage = error.localizedDescription
    } catch {
      guard !Task.isCancelled else { return }
      appState.markMediaOffline()
      transientMessage = "网络暂时不可用，已保留当前资料库。"
    }
  }
}

private struct FolderCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.90 : 1)
      .animation(.spring(response: 0.24, dampingFraction: 0.86), value: configuration.isPressed)
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

private struct PhotoFileCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ZStack {
        LinearGradient(
          colors: [Color.secondary.opacity(0.13), Color.secondary.opacity(0.05)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Image(systemName: "photo.fill")
          .font(.system(size: 32, weight: .medium))
          .foregroundStyle(.secondary.opacity(0.72))
      }
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      Text(item.name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)

      HStack(spacing: 5) {
        Text(item.formattedSize)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 2)
        if appState.libraryStore.isFavorite(item) {
          Image(systemName: "heart.fill")
            .font(.caption2)
            .foregroundStyle(CinevaTheme.accent)
        }
      }
    }
    .contentShape(Rectangle())
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

private struct PhotoListRow: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem

  var body: some View {
    HStack(spacing: 13) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.secondary.opacity(0.10))
        Image(systemName: "photo.fill")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      .frame(width: 82, height: 48)

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
    guard item.duration > 0 else { return 0 }
    let position = appState.libraryStore.resumePosition(for: item)
    guard position > 2, position < item.duration - 8 else { return 0 }
    return min(max(position / item.duration, 0), 1)
  }
}
