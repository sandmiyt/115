import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  @Environment(\.artworkRefreshRevision) private var parentArtworkRevision
  @State private var retryRevision = 0
  let item: CloudItem
  var transitionNamespace: Namespace.ID? = nil
  var compact = false
  var selectionMode = false
  var isSelected = false
  @Environment(\.mediaGridTapGate) private var tapGate
  let onOpen: () -> Void

  var body: some View {
    Button {
      guard tapGate?.allowsTap != false else { return }
      onOpen()
    } label: {
      VStack(alignment: .leading, spacing: 7) {
        MediaArtworkCard(item: item, progress: resumeProgress, compact: compact)
          .cinevaPlayerTransitionSource(id: item.id, in: transitionNamespace)
          .overlay(alignment: .topTrailing) {
            if selectionMode && item.isVideo {
              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : .white)
                .background(.black.opacity(0.35), in: Circle())
                .padding(7)
            } else if appState.libraryStore.isFavorite(item) {
              Image(systemName: "heart.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(.black.opacity(0.40), in: Circle())
                .padding(7)
            }
          }

        if !compact {
          Text(item.name)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading)
        }
      }
      .contentShape(Rectangle())
    }
    .environment(\.artworkRefreshRevision, parentArtworkRevision &+ retryRevision)
    .buttonStyle(MediaCardButtonStyle())
    .disabled(selectionMode && !item.isVideo)
    .accessibilityLabel(item.name)
    .accessibilityHint(selectionMode ? "切换选择" : (item.isPhoto ? "查看照片预览" : "播放视频"))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .contextMenu {
      if !selectionMode {
        Button { retryRevision &+= 1 } label: {
          Label("重试缩略图", systemImage: "arrow.clockwise")
        }
        Button {
          appState.libraryStore.toggleFavorite(item)
          let feedback = UIImpactFeedbackGenerator(style: .medium)
          feedback.prepare()
          feedback.impactOccurred(intensity: 0.82)
        } label: {
          Label(
            appState.libraryStore.isFavorite(item) ? "取消收藏" : "收藏",
            systemImage: appState.libraryStore.isFavorite(item) ? "heart.slash" : "heart"
          )
        }
      }
    }
  }

  private var resumeProgress: Double {
    let duration = appState.libraryStore.knownDuration(for: item)
    guard duration > 0 else { return 0 }
    let position = appState.libraryStore.resumePosition(for: item)
    guard position > 2, position < duration - 8 else { return 0 }
    return min(max(position / duration, 0), 1)
  }
}

struct MediaArtworkCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let progress: Double?
  var compact = false

  var body: some View {
    ZStack(alignment: .bottom) {
      VideoArtwork(item: item, aspectRatio: compact ? 1 : 16 / 9, fillsFrame: compact)

      LinearGradient(
        colors: [.clear, .black.opacity(0.34)],
        startPoint: .center,
        endPoint: .bottom
      )
      .allowsHitTesting(false)

      HStack(alignment: .bottom) {
        Spacer(minLength: 0)

        if !effectiveDurationText.isEmpty {
          Text(effectiveDurationText)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
        }
      }
      .padding(6)

      if let progress, progress > 0.002 {
        GeometryReader { proxy in
          VStack(spacing: 0) {
            Spacer()
            ZStack(alignment: .leading) {
              Rectangle().fill(.white.opacity(0.24))
              Rectangle()
                .fill(CinevaTheme.accent)
                .frame(width: max(2, proxy.size.width * min(max(progress, 0), 1)))
            }
            .frame(height: 3)
          }
        }
        .allowsHitTesting(false)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: compact ? 3 : 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: compact ? 3 : 14, style: .continuous)
        .stroke(.primary.opacity(0.08), lineWidth: 0.6)
    }

  }

  private var effectiveDurationText: String {
    let duration = appState.libraryStore.knownDuration(for: item)
    guard duration > 0 else { return "" }
    let total = Int(duration.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%02d:%02d", minutes, seconds)
  }
}

private struct ArtworkRefreshRevisionKey: EnvironmentKey {
  static let defaultValue = 0
}

extension EnvironmentValues {
  var artworkRefreshRevision: Int {
    get { self[ArtworkRefreshRevisionKey.self] }
    set { self[ArtworkRefreshRevisionKey.self] = newValue }
  }
}

/// Cached artwork with stable geometry: square grid tiles or aspect-fit landscape cards.
struct VideoArtwork: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppState.self) private var appState
  @Environment(\.artworkRefreshRevision) private var artworkRefreshRevision
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let item: CloudItem
  var aspectRatio: CGFloat = 16 / 9
  var fillsFrame = false

  @State private var cachedImage: UIImage?
  @State private var loadedIdentity: String?
  @State private var renderedItemIdentity: String?
  @State private var activeRequestIdentity: String?
  @State private var isLoading = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        artworkBackground
          .frame(width: proxy.size.width, height: proxy.size.height)

        if let image = (renderedItemIdentity == itemThumbnailIdentity ? cachedImage : nil)
          ?? appState.thumbnailService.cachedThumbnail(for: item) {
          artwork(Image(uiImage: image), in: proxy.size)
            .transition(.opacity)
        } else {
          ZStack {
            placeholder
            if isLoading {
              ProgressView()
                .controlSize(.small)
                .tint(.secondary)
            }
          }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .clipped()
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .task(id: "\(itemThumbnailIdentity)|\(artworkRefreshRevision)|\(scenePhase)") {
      guard scenePhase == .active else { return }
      let identity = itemThumbnailIdentity
      if renderedItemIdentity != identity {
        cachedImage = nil
        renderedItemIdentity = identity
      }
      if loadedIdentity == identity, cachedImage != nil { return }
      activeRequestIdentity = identity
      isLoading = false
      // Keep already-rendered artwork visible during a directory refresh. A
      // changed/revalidated thumbnail replaces it only after the new image is
      // ready, so existing cards never fall back to placeholders together.
      let spinner = Task { @MainActor in
        do { try await Task.sleep(nanoseconds: 180_000_000) }
        catch { return }
        guard !Task.isCancelled, cachedImage == nil else { return }
        isLoading = true
      }
      defer {
        spinner.cancel()
        if activeRequestIdentity == identity {
          isLoading = false
        }
      }
      let service = appState.thumbnailService
      let api = appState.api
      let requestedItem = item
      let image = await withTaskCancellationHandler {
        var result: UIImage?
        // Queue time is not a download failure. Each active network/frame stage
        // has its own deadline; a busy directory must not expire queued cards.
        var attempt = 0
        while !Task.isCancelled {
          let delay = [0, 6, 15, 30, 60][min(attempt, 4)]
          if delay > 0 {
            spinner.cancel()
            isLoading = false
            do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
            catch { return nil as UIImage? }
          }
          guard !Task.isCancelled else { return nil as UIImage? }
          result = await service.thumbnail(for: requestedItem, api: api)
          if result != nil { break }
          attempt = min(attempt + 1, 4)
        }
        return result
      } onCancel: {
        spinner.cancel()
      }
      guard !Task.isCancelled else { return }
      guard let image else { return }
      let shouldFadeIn = cachedImage == nil && isLoading && !reduceMotion
      withAnimation(shouldFadeIn ? .easeOut(duration: 0.16) : nil) {
        cachedImage = image
        loadedIdentity = identity
        isLoading = false
      }
    }
  }

  private var itemThumbnailIdentity: String {
    // WebDAV/OpenList may normalize modification timestamps during a forced
    // directory refresh even when the underlying file is unchanged. ID + size
    // keeps the visible card stable; the durable cache still includes mtime and
    // therefore continues to invalidate replaced files across launches.
    "\(appState.mediaSourceRevision)|\(item.id)|\(item.size)"
  }

  @ViewBuilder
  private func artwork(_ image: Image, in size: CGSize) -> some View {
    switch fillsFrame ? .fill : appState.artworkMode {
    case .fit:
      ZStack {
        // A static cinema-toned bed avoids a second full-size image render and
        // per-card blur during fast scrolling while the real artwork remains
        // completely visible and uncropped.
        LinearGradient(
          colors: [.black.opacity(0.92), .black.opacity(0.72)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )

        image
          .resizable()
          .scaledToFit()
          .frame(width: size.width, height: size.height, alignment: .center)
      }
      .frame(width: size.width, height: size.height)
      .clipped()

    case .fill:
      image
        .resizable()
        .scaledToFill()
        .frame(width: size.width, height: size.height, alignment: .center)
        .clipped()
    }
  }

  private var artworkBackground: some View {
    LinearGradient(
      colors: [
        Color.secondary.opacity(0.15),
        Color.secondary.opacity(0.06),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var placeholder: some View {
    ZStack {
      artworkBackground
      Image(systemName: item.isPhoto ? "photo" : "play.rectangle.fill")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.secondary.opacity(0.72))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension View {
  /// Opts a cover into the system zoom transition on iOS 18 while retaining
  /// the existing full-screen presentation on iOS 17.
  @ViewBuilder
  func cinevaPlayerTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
    if #available(iOS 18.0, *), let namespace {
      matchedTransitionSource(id: id, in: namespace)
    } else {
      self
    }
  }

  @ViewBuilder
  func cinevaPlayerZoomTransition(sourceID: String, in namespace: Namespace.ID) -> some View {
    modifier(CinevaZoomTransition(sourceID: sourceID, namespace: namespace))
  }
}

private struct CinevaZoomTransition: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let sourceID: String
  let namespace: Namespace.ID?

  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 18.0, *), let namespace, !reduceMotion {
      content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
    } else {
      content
    }
  }
}

private struct MediaCardButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
      .opacity(configuration.isPressed ? 0.90 : 1)
      .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
  }
}

/// A cached, aspect-fit photo preview. Photo selections never enter the video engine.
struct PhotoPreviewScreen: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let item: CloudItem
  @State private var image: UIImage?
  @State private var loading = true
  @State private var retry = 0

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if !appState.isAppUnlocked {
          Image(systemName: "lock.fill").foregroundStyle(.white)
        } else if let image {
          Image(uiImage: image).resizable().scaledToFit()
            .accessibilityLabel(item.name)
            .transition(.opacity)
        } else if loading {
          ProgressView().tint(.white)
        } else {
          ContentUnavailableView {
            Label("暂时无法预览", systemImage: "photo")
          } description: {
            Text("请检查网络后重试。")
          } actions: {
            Button("重试") { retry += 1 }
          }
        }
      }
      .preferredColorScheme(.dark)
      .navigationTitle("照片预览")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("完成") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            appState.libraryStore.toggleFavorite(item)
          } label: {
            Image(systemName: appState.libraryStore.isFavorite(item) ? "heart.fill" : "heart")
          }
          .accessibilityLabel(appState.libraryStore.isFavorite(item) ? "取消收藏" : "收藏")
          .disabled(!appState.isAppUnlocked)
        }
      }
      .task(id: "\(retry)|\(appState.isAppUnlocked)") {
        guard appState.isAppUnlocked else { return }
        loading = true
        let loaded = await appState.thumbnailService.thumbnail(for: item, api: appState.api)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
          image = loaded
          loading = false
        }
      }
    }
  }
}

/// A reference gate avoids invalidating every card on each gesture sample.
private final class MediaGridTapGate {
  var blockedUntil: TimeInterval = 0
  var hasMultipleTouches = false
  var allowsTap: Bool { !hasMultipleTouches && ProcessInfo.processInfo.systemUptime >= blockedUntil }
  func suppressTap() { blockedUntil = ProcessInfo.processInfo.systemUptime + 0.5 }
}

private struct MediaGridTapGateKey: EnvironmentKey {
  static let defaultValue: MediaGridTapGate? = nil
}

private extension EnvironmentValues {
  var mediaGridTapGate: MediaGridTapGate? {
    get { self[MediaGridTapGateKey.self] }
    set { self[MediaGridTapGateKey.self] = newValue }
  }
}

struct MediaSelectionBar: View {
  let count: Int
  let onSelectAll: () -> Void
  let onDone: () -> Void
  let onFavorite: (() -> Void)?
  let onUnfavorite: () -> Void

  var body: some View {
    VStack(spacing: 4) {
      HStack {
        Text("已选 \(count) 个视频").font(.subheadline.weight(.medium))
        Spacer()
        Button("完成", action: onDone)
      }
      HStack(spacing: 16) {
        Button("全选已加载", action: onSelectAll)
        Spacer(minLength: 8)
        if let onFavorite { Button("收藏", action: onFavorite).disabled(count == 0) }
        Button("取消收藏", action: onUnfavorite).disabled(count == 0)
      }
      .frame(minHeight: 44)
    }
    .padding(.horizontal, 16).padding(.top, 10)
    .background(.regularMaterial)
  }
}


enum PhotoGridSection: Int, CaseIterable { case folders, media, footer }
enum PhotoGridID: Hashable { case folder(String), media(String), footer }

/// The collection view owns scrolling, reuse and interactive layout transitions.
/// There is no scaled scroll surface or second SwiftUI scroll-position controller.
struct PhotoLibraryGrid<FolderCell: View, MediaCell: View, Footer: View>: UIViewRepresentable {
  @Environment(AppState.self) private var appState
  @Environment(\.artworkRefreshRevision) private var artworkRevision
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let folders: [CloudItem]
  let items: [CloudItem]
  @Binding var columnCount: Int
  let folderColumns: Int
  let compact: Bool
  let resetKey: String
  let onRefresh: (() async -> Void)?
  let folderCell: (CloudItem) -> FolderCell
  let mediaCell: (CloudItem) -> MediaCell
  let footer: () -> Footer

  init(folders: [CloudItem], items: [CloudItem], columnCount: Binding<Int>, folderColumns: Int,
       compact: Bool, resetKey: String, onRefresh: (() async -> Void)? = nil,
       @ViewBuilder folder: @escaping (CloudItem) -> FolderCell,
       @ViewBuilder media: @escaping (CloudItem) -> MediaCell,
       @ViewBuilder footer: @escaping () -> Footer) {
    self.folders = folders; self.items = items; self._columnCount = columnCount
    self.folderColumns = folderColumns; self.compact = compact; self.resetKey = resetKey
    self.onRefresh = onRefresh; self.folderCell = folder; self.mediaCell = media; self.footer = footer
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
  func makeUIView(context: Context) -> UICollectionView {
    let view = UICollectionView(frame: .zero, collectionViewLayout: context.coordinator.newLayout())
    view.backgroundColor = .clear
    view.alwaysBounceVertical = true
    view.keyboardDismissMode = .interactive
    view.isPrefetchingEnabled = false
    view.panGestureRecognizer.maximumNumberOfTouches = 1
    context.coordinator.install(view)
    return view
  }
  func updateUIView(_ uiView: UICollectionView, context: Context) {
    let changedScope = context.coordinator.parent.resetKey != resetKey
    context.coordinator.parent = self
    if changedScope, context.coordinator.transition != nil {
      context.coordinator.complete(finish: false)
    }
    context.coordinator.applyLatest()
  }
  static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.refreshTask?.cancel()
    coordinator.releaseTouchOwnership()
    if coordinator.transition != nil, !coordinator.finishing { uiView.cancelInteractiveTransition() }
    uiView.removeGestureRecognizer(coordinator.pinch)
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate, UICollectionViewDelegate {
    var parent: PhotoLibraryGrid
    weak var view: UICollectionView?
    var dataSource: UICollectionViewDiffableDataSource<PhotoGridSection, PhotoGridID>!
    var foldersByID: [String: CloudItem] = [:]
    var mediaByID: [String: CloudItem] = [:]
    private let tapGate = MediaGridTapGate()
    var transition: UICollectionViewTransitionLayout?
    var finishing = false
    var active = true
    var anchorIndex: IndexPath?
    var anchorFraction: CGFloat = 0.5
    var anchorScreenY: CGFloat = 0
    var targetRatio: CGFloat = 1
    var scope: String?
    var refreshTask: Task<Void, Never>?
    lazy var pinch = LibraryPriorityPinchRecognizer(target: self, action: #selector(handlePinch(_:)))

    init(parent: PhotoLibraryGrid) { self.parent = parent }
    func newLayout(columns: Int? = nil) -> PhotoGridLayout {
      PhotoGridLayout(mediaColumns: columns ?? MediaGridZoomPolicy.normalized(parent.columnCount),
                      folderColumns: parent.folderColumns, compact: parent.compact)
    }
    func install(_ view: UICollectionView) {
      self.view = view
      view.delegate = self
      view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "photo-cell")
      dataSource = UICollectionViewDiffableDataSource(collectionView: view) { [weak self] view, path, id in
        guard let self else { return nil }
        let cell = view.dequeueReusableCell(withReuseIdentifier: "photo-cell", for: path)
        switch id {
        case .folder(let key):
          guard let item = self.foldersByID[key] else { return cell }
          let content = self.parent.folderCell(item).environment(self.parent.appState)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
        case .media(let key):
          guard let item = self.mediaByID[key] else { return cell }
          let content = self.parent.mediaCell(item).environment(self.parent.appState)
            .environment(\.artworkRefreshRevision, self.parent.artworkRevision)
            .environment(\.mediaGridTapGate, self.tapGate)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
        case .footer:
          let content = self.parent.footer().environment(self.parent.appState)
          cell.contentConfiguration = UIHostingConfiguration { content }.margins(.all, 0)
        }
        return cell
      }
      pinch.shouldClaim = { [weak self] point in
        guard let self, let view = self.view, view.numberOfSections > 1,
          view.numberOfItems(inSection: 1) > 0 else { return false }
        let layout = (self.transition?.currentLayout ?? view.collectionViewLayout) as? PhotoGridLayout
        return layout?.mediaRegion.contains(point) == true
      }
      pinch.onClaim = { [weak self] in
        guard let self else { return }
        self.tapGate.hasMultipleTouches = true
        self.tapGate.suppressTap()
        self.view?.panGestureRecognizer.isEnabled = false
      }
      pinch.onRelease = { [weak self] in self?.releaseTouchOwnership() }
      pinch.delegate = self
      pinch.cancelsTouchesInView = true
      view.addGestureRecognizer(pinch)
      if parent.onRefresh != nil {
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        view.refreshControl = refresh
      }
      applyLatest()
    }

    func applyLatest() {
      guard active, !tapGate.hasMultipleTouches, !finishing, transition == nil, let view else { return }
      foldersByID = Dictionary(parent.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      mediaByID = Dictionary(parent.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var seen = Set<PhotoGridID>()
      var snapshot = NSDiffableDataSourceSnapshot<PhotoGridSection, PhotoGridID>()
      snapshot.appendSections(PhotoGridSection.allCases)
      snapshot.appendItems(parent.folders.map { PhotoGridID.folder($0.id) }.filter { seen.insert($0).inserted }, toSection: .folders)
      snapshot.appendItems(parent.items.map { PhotoGridID.media($0.id) }.filter { seen.insert($0).inserted }, toSection: .media)
      snapshot.appendItems([.footer], toSection: .footer)
      let old = Set(dataSource.snapshot().itemIdentifiers)
      let visible = view.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
      snapshot.reconfigureItems(visible.filter { old.contains($0) && seen.contains($0) || $0 == .footer && old.contains($0) })
      dataSource.apply(snapshot, animatingDifferences: false)
      if let layout = view.collectionViewLayout as? PhotoGridLayout,
        layout.mediaColumns != MediaGridZoomPolicy.normalized(parent.columnCount)
          || layout.folderColumns != parent.folderColumns || layout.compact != parent.compact {
        view.setCollectionViewLayout(newLayout(), animated: false)
      }
      if scope != parent.resetKey {
        scope = parent.resetKey
        view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
      }
    }

    @objc func refreshRequested() {
      guard refreshTask == nil, let action = parent.onRefresh else { return }
      refreshTask = Task { @MainActor [weak self] in
        await action()
        guard let self else { return }
        self.view?.refreshControl?.endRefreshing()
        self.refreshTask = nil
      }
    }

    func collectionView(_ collectionView: UICollectionView,
                        transitionLayoutForOldLayout fromLayout: UICollectionViewLayout,
                        newLayout toLayout: UICollectionViewLayout) -> UICollectionViewTransitionLayout {
      let layout = PhotoGridTransitionLayout(currentLayout: fromLayout, nextLayout: toLayout)
      layout.anchorIndex = anchorIndex
      layout.anchorFraction = anchorFraction
      layout.anchorScreenY = anchorScreenY
      return layout
    }

    func releaseTouchOwnership() {
      tapGate.hasMultipleTouches = false
      tapGate.suppressTap()
      view?.panGestureRecognizer.isEnabled = true
      applyLatest()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard !finishing, transition == nil, let view,
        let layout = view.collectionViewLayout as? PhotoGridLayout else { return false }
      let point = gestureRecognizer.location(in: view)
      return layout.mediaRegion.contains(point) && view.numberOfItems(inSection: 1) > 0
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      // Keep a first-finger scroll from failing the still-possible pinch.
      otherGestureRecognizer === view?.panGestureRecognizer
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard active, let view else { return }
      tapGate.suppressTap()
      switch recognizer.state {
      case .began:
        let point = recognizer.location(in: view)
        anchorIndex = view.indexPathsForVisibleItems.filter { $0.section == 1 }.min {
          let first = view.layoutAttributesForItem(at: $0)?.center ?? .zero
          let second = view.layoutAttributesForItem(at: $1)?.center ?? .zero
          return hypot(first.x - point.x, first.y - point.y) < hypot(second.x - point.x, second.y - point.y)
        }
        if let anchorIndex, let frame = view.layoutAttributesForItem(at: anchorIndex)?.frame {
          anchorFraction = min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1)
        }
        anchorScreenY = point.y - view.contentOffset.y
      case .changed:
        guard !finishing else { return }
        if transition == nil {
          guard abs(recognizer.scale - 1) > 0.015,
            let current = view.collectionViewLayout as? PhotoGridLayout,
            let index = MediaGridZoomPolicy.levels.firstIndex(of: current.mediaColumns) else { return }
          let next = min(max(index + (recognizer.scale > 1 ? -1 : 1), 0), MediaGridZoomPolicy.levels.count - 1)
          guard next != index else { return }
          let target = newLayout(columns: MediaGridZoomPolicy.levels[next])
          targetRatio = target.mediaWidth(in: view.bounds.width) / current.mediaWidth(in: view.bounds.width)
          current.focus = (anchorIndex, anchorFraction, anchorScreenY)
          target.focus = (anchorIndex, anchorFraction, anchorScreenY)
          transition = view.startInteractiveTransition(to: target) { [weak self] _, completed in
            guard let self, self.active else { return }
            self.transition = nil
            if let view = self.view, let layout = view.collectionViewLayout as? PhotoGridLayout {
              // UIKit can reset the offset when it installs the final layout.
              view.setContentOffset(layout.targetContentOffset(forProposedContentOffset: view.contentOffset), animated: false)
              layout.focus = nil
            }
            Task { @MainActor [weak self] in
              await Task.yield()
              guard let self, self.active else { return }
              if completed { self.parent.columnCount = target.mediaColumns }
              self.pinch.scale = 1
              self.finishing = false
              self.applyLatest()
            }
          }
        }
        guard let transition else { return }
        anchorScreenY = recognizer.location(in: view).y - view.contentOffset.y
        (transition.currentLayout as? PhotoGridLayout)?.focus = (anchorIndex, anchorFraction, anchorScreenY)
        (transition.nextLayout as? PhotoGridLayout)?.focus = (anchorIndex, anchorFraction, anchorScreenY)
        (transition as? PhotoGridTransitionLayout)?.anchorScreenY = anchorScreenY
        transition.transitionProgress = CGFloat(PhotoGridTransitionPolicy.progress(
          magnification: Double(recognizer.scale), targetRatio: Double(targetRatio)))
        transition.invalidateLayout()
        view.layoutIfNeeded()
        if transition.transitionProgress >= 1 { complete(finish: true) }
        else if (targetRatio > 1 && recognizer.scale < 0.985)
          || (targetRatio < 1 && recognizer.scale > 1.015) {
          complete(finish: false)
        }
      case .ended:
        if let transition, !finishing {
          let projected = PhotoGridTransitionPolicy.projectedProgress(
            progress: Double(transition.transitionProgress), velocity: Double(recognizer.velocity),
            targetRatio: Double(targetRatio))
          complete(finish: projected >= 0.5)
        }
      case .cancelled, .failed:
        if transition != nil, !finishing { complete(finish: false) }
      default: break
      }
    }

    func complete(finish: Bool) {
      guard let view, transition != nil, !finishing else { return }
      finishing = true
      if parent.reduceMotion { transition?.transitionProgress = finish ? 1 : 0 }
      if finish { view.finishInteractiveTransition() }
      else { view.cancelInteractiveTransition() }
    }
  }
}

/// Calculate only rows intersecting the viewport, even in very large directories.
final class PhotoGridLayout: UICollectionViewLayout {
  let mediaColumns: Int
  let folderColumns: Int
  let compact: Bool
  var focus: (IndexPath?, CGFloat, CGFloat)?
  init(mediaColumns: Int, folderColumns: Int, compact: Bool) {
    self.mediaColumns = mediaColumns; self.folderColumns = max(1, folderColumns); self.compact = compact
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("Programmatic layout only") }
  private var width: CGFloat { max(collectionView?.bounds.width ?? 1, 1) }
  private func count(_ section: Int) -> Int {
    guard let collectionView, collectionView.numberOfSections > section else { return 0 }
    return collectionView.numberOfItems(inSection: section)
  }
  func mediaWidth(in width: CGFloat) -> CGFloat {
    max(1, (width - (compact ? 4 : 20) - CGFloat(mediaColumns - 1) * (compact ? 2 : 9)) / CGFloat(mediaColumns))
  }
  private var folderWidth: CGFloat { max(1, (width - 20 - CGFloat(folderColumns - 1) * 9) / CGFloat(folderColumns)) }
  private var folderHeight: CGFloat {
    folderWidth * 9 / 16 + UIFont.preferredFont(forTextStyle: .subheadline).lineHeight * 2
      + UIFont.preferredFont(forTextStyle: .caption2).lineHeight + 16
  }
  private var folderBottom: CGFloat {
    count(0) == 0 ? 0 : 10 + CGFloat((count(0) + folderColumns - 1) / folderColumns) * (folderHeight + 11)
  }
  private var mediaHeight: CGFloat {
    compact ? mediaWidth(in: width) : mediaWidth(in: width) * 9 / 16 + UIFont.preferredFont(forTextStyle: .caption1).lineHeight * 2 + 7
  }
  private var mediaTop: CGFloat { folderBottom + (count(0) == 0 ? 2 : 3) }
  private var mediaBottom: CGFloat { mediaTop + CGFloat((count(1) + mediaColumns - 1) / mediaColumns) * (mediaHeight + (compact ? 2 : 11)) }
  var mediaRegion: CGRect { CGRect(x: 0, y: mediaTop, width: width, height: max(0, mediaBottom - mediaTop)) }
  override var collectionViewContentSize: CGSize { CGSize(width: width, height: mediaBottom + 88) }

  override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard path.item < count(path.section) else { return nil }
    let attribute = UICollectionViewLayoutAttributes(forCellWith: path)
    if path.section == 2 { attribute.frame = CGRect(x: 0, y: mediaBottom, width: width, height: 88); return attribute }
    let folder = path.section == 0
    let columns = folder ? folderColumns : mediaColumns
    let gap: CGFloat = folder ? 9 : (compact ? 2 : 9)
    let inset: CGFloat = folder ? 10 : (compact ? 2 : 10)
    let itemWidth = folder ? folderWidth : mediaWidth(in: width)
    let itemHeight = folder ? folderHeight : mediaHeight
    let rowGap: CGFloat = folder ? 11 : (compact ? 2 : 11)
    attribute.frame = CGRect(x: inset + CGFloat(path.item % columns) * (itemWidth + gap),
      y: (folder ? 10 : mediaTop) + CGFloat(path.item / columns) * (itemHeight + rowGap), width: itemWidth, height: itemHeight)
    return attribute
  }
  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    var attributes: [UICollectionViewLayoutAttributes] = []
    for section in 0...1 {
      let columns = section == 0 ? folderColumns : mediaColumns
      let top: CGFloat = section == 0 ? 10 : mediaTop
      let stride = section == 0 ? folderHeight + 11 : mediaHeight + (compact ? 2 : 11)
      let first = max(0, Int(floor((rect.minY - top) / stride))) * columns
      let last = min(count(section), max(0, Int(ceil((rect.maxY - top) / stride)) + 1) * columns)
      if first < last {
        for index in first..<last {
          if let attribute = layoutAttributesForItem(at: IndexPath(item: index, section: section)), attribute.frame.intersects(rect) { attributes.append(attribute) }
        }
      }
    }
    if let footer = layoutAttributesForItem(at: IndexPath(item: 0, section: 2)), footer.frame.intersects(rect) { attributes.append(footer) }
    return attributes
  }
  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != collectionView?.bounds.size }
  override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
    guard let collectionView, let (index, fraction, screenY) = focus, let index,
      let frame = layoutAttributesForItem(at: index)?.frame else { return proposedContentOffset }
    let minimum = -collectionView.adjustedContentInset.top
    let maximum = max(minimum, collectionViewContentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    return CGPoint(x: 0, y: min(max(frame.minY + frame.height * fraction - screenY, minimum), maximum))
  }
}

/// Keeps the same content point under the fingers during BOTH dragging and UIKit's
/// finish/cancel animation. Inspired by TLLayoutTransitioning's offset control;
/// uses UIKit attributes directly instead of enumerating every item per frame.
final class PhotoGridTransitionLayout: UICollectionViewTransitionLayout {
  var anchorIndex: IndexPath?
  var anchorFraction: CGFloat = 0.5
  var anchorScreenY: CGFloat = 0

  override var transitionProgress: CGFloat {
    didSet {
      guard let collectionView, let anchorIndex,
        let start = currentLayout.layoutAttributesForItem(at: anchorIndex)?.frame,
        let end = nextLayout.layoutAttributesForItem(at: anchorIndex)?.frame else { return }
      let progress = min(max(transitionProgress, 0), 1)
      let startY = start.minY + start.height * anchorFraction
      let endY = end.minY + end.height * anchorFraction
      let y = startY + (endY - startY) * progress - anchorScreenY
      let minimum = -collectionView.adjustedContentInset.top
      let maximum = max(minimum, collectionViewContentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
      collectionView.setContentOffset(CGPoint(x: 0, y: min(max(y, minimum), maximum)), animated: false)
    }
  }

  override var collectionViewContentSize: CGSize {
    let start = currentLayout.collectionViewContentSize
    let end = nextLayout.collectionViewContentSize
    let progress = min(max(transitionProgress, 0), 1)
    return CGSize(width: start.width + (end.width - start.width) * progress,
                  height: start.height + (end.height - start.height) * progress)
  }
}

/// A card's hosted recognizers must not fail the parent pinch while the first
/// finger is down. Claim two-touch intent before UIPinch reaches .began so even
/// an unsuccessful pinch cannot turn into a card activation.
final class LibraryPriorityPinchRecognizer: UIPinchGestureRecognizer {
  var shouldClaim: ((CGPoint) -> Bool)?
  var onClaim: (() -> Void)?
  var onRelease: (() -> Void)?
  private var trackedTouches = Set<UITouch>()
  private var claimed = false

  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
    if let view, let other = preventingGestureRecognizer.view,
      other === view || other.isDescendant(of: view) { return false }
    // Navigation/system gestures outside this collection keep their normal priority.
    return super.canBePrevented(by: preventingGestureRecognizer)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    trackedTouches.formUnion(touches)
    if !claimed, trackedTouches.count >= 2, let view {
      let points = trackedTouches.map { $0.location(in: view) }
      let center = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                           y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
      if shouldClaim?(center) == true {
        claimed = true
        onClaim?()
      }
    }
    super.touchesBegan(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    trackedTouches.subtract(touches)
    super.touchesEnded(touches, with: event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    trackedTouches.subtract(touches)
    super.touchesCancelled(touches, with: event)
  }

  override func reset() {
    super.reset()
    trackedTouches.removeAll()
    if claimed { claimed = false; onRelease?() }
  }
}
