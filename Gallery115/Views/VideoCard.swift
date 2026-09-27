import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  var transitionNamespace: Namespace.ID? = nil
  var compact = false
  var selectionMode = false
  var isSelected = false
  var onLocate: (() -> Void)? = nil
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
                .font(.system(size: 18, weight: .semibold))
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
    .buttonStyle(MediaCardButtonStyle())
    .disabled(selectionMode && !item.isVideo)
    .accessibilityLabel(item.name)
    .accessibilityHint(selectionMode ? "切换选择" : (item.isPhoto ? "查看照片预览" : "播放视频"))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .contextMenu {
      if !selectionMode {
        if let onLocate {
          Button("定位到位置", systemImage: "location") { onLocate() }
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
  @Environment(\.displayScale) private var displayScale
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

        if let image = (renderedItemIdentity == itemMediaIdentity ? cachedImage : nil)
          ?? appState.thumbnailService.cachedThumbnail(for: item) {
          artwork(Image(uiImage: image), in: proxy.size)
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
      .task(id: "\(itemThumbnailIdentity)|\(ArtworkSizeTier.pixels(for: Int(max(proxy.size.width, proxy.size.height) * displayScale)))|\(artworkRefreshRevision)|\(scenePhase)") {
        await loadArtwork(pixels: ArtworkSizeTier.pixels(for: Int(max(proxy.size.width, proxy.size.height) * displayScale)))
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
  }

  @MainActor
  private func loadArtwork(pixels: Int) async {
    guard scenePhase == .active else { return }
    let identity = "\(itemThumbnailIdentity)|\(pixels)"
    if renderedItemIdentity != itemMediaIdentity {
      cachedImage = nil
      renderedItemIdentity = itemMediaIdentity
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
        result = await service.thumbnail(for: requestedItem, api: api, targetPixels: pixels)
        if result != nil { break }
        attempt = min(attempt + 1, 4)
      }
      return result
    } onCancel: {
      spinner.cancel()
    }
    guard !Task.isCancelled else { return }
    guard let image else { return }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      GridArtworkTrace.event("cell-image", id: appState.thumbnailService.traceKey(for: item), detail: "pixels=\(pixels)")
      cachedImage = image
      loadedIdentity = identity
      isLoading = false
    }

  }

  private var itemMediaIdentity: String {
    "\(appState.mediaSourceRevision)|\(item.id)"
  }

  private var itemThumbnailIdentity: String {
    // Content version is independent of rotating URLs and the requested tier.
    "\(appState.mediaSourceRevision)|\(item.id)|\(item.size)|\(item.modifiedAt.timeIntervalSince1970.rounded(.down))"
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
  let scrollRequest: MediaScrollRequest?
  let selectionMode: Bool
  let selectedIDs: Set<String>
  let onSelectionChange: ((Set<String>) -> Void)?
  let contentRevision: String
  let folderCell: (CloudItem) -> FolderCell
  let mediaCell: (CloudItem) -> MediaCell
  let footer: () -> Footer

  init(folders: [CloudItem], items: [CloudItem], columnCount: Binding<Int>, folderColumns: Int,
       compact: Bool, resetKey: String, onRefresh: (() async -> Void)? = nil,
       scrollRequest: MediaScrollRequest? = nil, selectionMode: Bool = false,
       selectedIDs: Set<String> = [], onSelectionChange: ((Set<String>) -> Void)? = nil,
       contentRevision: String = "",
       @ViewBuilder folder: @escaping (CloudItem) -> FolderCell,
       @ViewBuilder media: @escaping (CloudItem) -> MediaCell,
       @ViewBuilder footer: @escaping () -> Footer) {
    self.folders = folders; self.items = items; self._columnCount = columnCount
    self.folderColumns = folderColumns; self.compact = compact; self.resetKey = resetKey
    self.onRefresh = onRefresh; self.folderCell = folder; self.mediaCell = media; self.footer = footer
    self.scrollRequest = scrollRequest; self.selectionMode = selectionMode
    self.selectedIDs = selectedIDs; self.onSelectionChange = onSelectionChange
    self.contentRevision = contentRevision
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
  func makeUIView(context: Context) -> UICollectionView {
    let view = UICollectionView(frame: .zero, collectionViewLayout: context.coordinator.newLayout())
    view.backgroundColor = .clear
    view.alwaysBounceVertical = true
    view.keyboardDismissMode = .interactive
    view.isPrefetchingEnabled = true
    view.clipsToBounds = true
    view.panGestureRecognizer.maximumNumberOfTouches = 1
    context.coordinator.install(view)
    return view
  }
  func updateUIView(_ uiView: UICollectionView, context: Context) {
    let changedScope = context.coordinator.parent.resetKey != resetKey
    context.coordinator.parent = self
    if changedScope { context.coordinator.cancelZoom() }
    context.coordinator.applyLatest()
  }
  static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.refreshTask?.cancel()
    coordinator.endDragSelection()
    coordinator.cancelPrefetches()
    coordinator.releaseTouchOwnership()
    coordinator.cancelZoom()
    uiView.removeGestureRecognizer(coordinator.pinch)
    uiView.removeGestureRecognizer(coordinator.selectionDrag)
    uiView.prefetchDataSource = nil
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    var parent: PhotoLibraryGrid
    weak var view: UICollectionView?
    var dataSource: UICollectionViewDiffableDataSource<PhotoGridSection, PhotoGridID>!
    var foldersByID: [String: CloudItem] = [:]
    var mediaByID: [String: CloudItem] = [:]
    private let tapGate = MediaGridTapGate()
    var zoom = PhotoGridZoomState()
    var active = true
    var pendingDataUpdate = false
    var zoomLink: CADisplayLink?
    var pendingPinch: (scale: Double, velocity: Double, point: CGPoint)?
    var anchorID: String?
    var anchorFraction = CGPoint(x: 0.5, y: 0.5)
    var anchorScreen = CGPoint.zero
    private let interactionOwner = UUID()
    private var interactionTask: Task<Void, Never>?
    var zoomWarmIDs = Set<String>()
    var lastWarmSignature = ""
    var lastItems: [CloudItem] = []
    var lastFolders: [CloudItem] = []
    var lastColumns: Int?
    var lastFolderColumns: Int?
    var lastWidth: CGFloat = 0
    var lastZoomTimestamp: CFTimeInterval?
    var snapshotGeneration = 0
    var scope: String?
    var refreshTask: Task<Void, Never>?
    struct PrefetchWork { let token: UUID; let task: Task<Void, Never> }
    var prefetchTasks: [String: PrefetchWork] = [:]
    var prefetchPaths: [IndexPath: (id: String, token: UUID)] = [:]
    var handledScrollRequest: UUID?
    var lastSelectedIDs = Set<String>()
    var lastSelectionMode = false
    var lastArtworkRevision = -1
    var lastContentRevision = ""
    var lastCompact: Bool?
    var dragStart: Int?
    var dragEnd: Int?
    var dragBase = Set<String>()
    var dragAdds = true
    var dragPoint = CGPoint.zero
    var dragScrollLink: CADisplayLink?
    lazy var pinch = LibraryPriorityPinchRecognizer(target: self, action: #selector(handlePinch(_:)))
    lazy var selectionDrag = LibrarySelectionRecognizer(target: self, action: #selector(handleSelectionDrag(_:)))

    init(parent: PhotoLibraryGrid) { self.parent = parent }
    func newLayout(columns: Int? = nil) -> PhotoGridLayout {
      PhotoGridLayout(mediaColumns: columns ?? MediaGridZoomPolicy.normalized(parent.columnCount),
                      folderColumns: parent.folderColumns, compact: parent.compact)
    }
    func install(_ view: UICollectionView) {
      self.view = view
      view.delegate = self
      view.prefetchDataSource = self
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
            .id(item.id)
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
        let layout = view.collectionViewLayout as? PhotoGridLayout
        return layout?.mediaRegion.contains(point) == true
      }
      pinch.onClaim = { [weak self] in
        guard let self else { return }
        self.endDragSelection()
        self.tapGate.hasMultipleTouches = true
        self.tapGate.suppressTap()
        self.view?.panGestureRecognizer.isEnabled = false
      }
      pinch.onRelease = { [weak self] in self?.releaseTouchOwnership() }
      pinch.delegate = self
      pinch.cancelsTouchesInView = true
      view.addGestureRecognizer(pinch)
      selectionDrag.minimumPressDuration = 0.25
      selectionDrag.numberOfTouchesRequired = 1
      selectionDrag.delegate = self
      selectionDrag.isEnabled = parent.selectionMode
      view.addGestureRecognizer(selectionDrag)
      if parent.onRefresh != nil {
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshRequested), for: .valueChanged)
        view.refreshControl = refresh
      }
      applyLatest()
    }

    func applyLatest() {
      guard active, let view else { return }
      guard !tapGate.hasMultipleTouches, zoom.phase == .idle else { pendingDataUpdate = true; return }
      pendingDataUpdate = false
      let layoutChanged = lastColumns != parent.columnCount || lastFolderColumns != parent.folderColumns || lastCompact != parent.compact
      if layoutChanged, let layout = view.collectionViewLayout as? PhotoGridLayout {
        layout.position = Double(MediaGridZoomPolicy.levels.firstIndex(of: MediaGridZoomPolicy.normalized(parent.columnCount)) ?? 2)
        layout.folderColumns = max(1, parent.folderColumns)
        layout.compact = parent.compact
        layout.invalidateLayout()
        zoom.position = layout.position
        lastColumns = parent.columnCount
        lastFolderColumns = parent.folderColumns
      }
      if scope == parent.resetKey, lastItems == parent.items, lastFolders == parent.folders,
        lastSelectedIDs == parent.selectedIDs, lastSelectionMode == parent.selectionMode,
        lastArtworkRevision == parent.artworkRevision, lastContentRevision == parent.contentRevision,
        lastCompact == parent.compact {
        applyScrollRequest()
        return
      }
      lastItems = parent.items; lastFolders = parent.folders
      selectionDrag.isEnabled = parent.selectionMode
      if scope != parent.resetKey { cancelPrefetches(); endDragSelection() }
      let previousMedia = mediaByID
      let previousFolders = foldersByID
      foldersByID = Dictionary(parent.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      mediaByID = Dictionary(parent.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for key in Array(prefetchTasks.keys) where previousMedia[key] != mediaByID[key] {
        prefetchTasks.removeValue(forKey: key)?.task.cancel()
      }
      var seen = Set<PhotoGridID>()
      var snapshot = NSDiffableDataSourceSnapshot<PhotoGridSection, PhotoGridID>()
      snapshot.appendSections(PhotoGridSection.allCases)
      snapshot.appendItems(parent.folders.map { PhotoGridID.folder($0.id) }.filter { seen.insert($0).inserted }, toSection: .folders)
      snapshot.appendItems(parent.items.map { PhotoGridID.media($0.id) }.filter { seen.insert($0).inserted }, toSection: .media)
      snapshot.appendItems([.footer], toSection: .footer)
      let old = Set(dataSource.snapshot().itemIdentifiers)
      let visible = view.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
      let allChanged = lastSelectionMode != parent.selectionMode || lastArtworkRevision != parent.artworkRevision
        || lastCompact != parent.compact || lastContentRevision != parent.contentRevision
      let selectionChanges = lastSelectedIDs.symmetricDifference(parent.selectedIDs)
      snapshot.reconfigureItems(visible.filter { id in
        guard old.contains(id) else { return false }
        switch id {
        case .footer: return true
        case .folder(let key): return seen.contains(id) && (allChanged || previousFolders[key] != foldersByID[key])
        case .media(let key):
          return seen.contains(id) && (allChanged || selectionChanges.contains(key) || previousMedia[key] != mediaByID[key])
        }
      })
      lastSelectedIDs = parent.selectedIDs
      lastSelectionMode = parent.selectionMode
      lastArtworkRevision = parent.artworkRevision
      lastContentRevision = parent.contentRevision
      lastCompact = parent.compact
      // UIKit index-path cancellations from an older snapshot cannot cancel a
      // new identity at the same position; task ownership remains media/token based.
      prefetchPaths.removeAll()
      snapshotGeneration &+= 1
      let generation = snapshotGeneration
      GridArtworkTrace.event("snapshot", id: parent.resetKey, detail: "generation=\(generation)")
      dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
        guard let self, self.snapshotGeneration == generation else { return }
        self.applyScrollRequest()
      }
      if scope != parent.resetKey {
        scope = parent.resetKey
        view.setContentOffset(CGPoint(x: 0, y: -view.adjustedContentInset.top), animated: false)
      }
    }

    func applyScrollRequest() {
      guard active, let view, zoom.phase == .idle, let request = parent.scrollRequest,
        handledScrollRequest != request.id,
        let path = dataSource.indexPath(for: .media(request.itemID)) else { return }
      handledScrollRequest = request.id
      view.layoutIfNeeded()
      view.scrollToItem(at: path, at: .centeredVertically, animated: !parent.reduceMotion)
    }

    func cancelPrefetches() {
      for work in prefetchTasks.values { work.task.cancel() }
      prefetchTasks.removeAll(); prefetchPaths.removeAll(); zoomWarmIDs.removeAll()
    }

    @discardableResult
    func prefetch(_ id: String, pixels: Int) -> UUID? {
      if let existing = prefetchTasks[id] { return existing.token }
      guard prefetchTasks.count < 48, let item = mediaByID[id] else { return nil }
      let service = parent.appState.thumbnailService, api = parent.appState.api
      let token = UUID()
      let task = Task(priority: .utility) { [weak self] in
        _ = await service.thumbnail(for: item, api: api, isPrefetch: true, targetPixels: pixels)
        guard let self, self.prefetchTasks[id]?.token == token else { return }
        self.prefetchTasks[id] = nil
        self.prefetchPaths = self.prefetchPaths.filter { $0.value.token != token }
      }
      prefetchTasks[id] = PrefetchWork(token: token, task: task)
      return token
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
      guard let layout = collectionView.collectionViewLayout as? PhotoGridLayout else { return }
      let pixels = Int(PhotoGridZoomState.width(at: layout.position, widths: layout.geometry.widths) * collectionView.traitCollection.displayScale)
      for path in indexPaths {
        guard case .media(let id) = dataSource.itemIdentifier(for: path), let token = prefetch(id, pixels: pixels) else { continue }
        prefetchPaths[path] = (id, token)
      }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
      for path in indexPaths {
        guard let old = prefetchPaths.removeValue(forKey: path), !zoomWarmIDs.contains(old.id),
          prefetchTasks[old.id]?.token == old.token else { continue }
        prefetchTasks.removeValue(forKey: old.id)?.task.cancel()
      }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
      guard case .media(let id) = dataSource.itemIdentifier(for: indexPath), let item = mediaByID[id] else { return }
      GridArtworkTrace.event("visible", id: parent.appState.thumbnailService.traceKey(for: item), detail: "ready=\(parent.appState.thumbnailService.cachedThumbnail(for: item) != nil)")
    }

    @objc func handleSelectionDrag(_ recognizer: UILongPressGestureRecognizer) {
      guard let view else { return }
      dragPoint = recognizer.location(in: view)
      switch recognizer.state {
      case .began:
        guard let path = view.indexPathForItem(at: dragPoint), path.section == 1,
          path.item < parent.items.count, parent.items[path.item].isVideo else { return }
        dragStart = path.item
        dragBase = parent.selectedIDs
        dragAdds = !dragBase.contains(parent.items[path.item].id)
        view.panGestureRecognizer.isEnabled = false
        tapGate.suppressTap()
        let link = CADisplayLink(target: self, selector: #selector(scrollDuringSelection))
        link.add(to: .main, forMode: .common)
        dragScrollLink = link
        updateDragSelection()
      case .changed: updateDragSelection()
      case .ended, .cancelled, .failed: endDragSelection()
      default: break
      }
    }

    func updateDragSelection() {
      guard let view, let start = dragStart,
        let path = view.indexPathForItem(at: dragPoint), path.section == 1 else { return }
      guard dragEnd != path.item else { return }
      dragEnd = path.item
      let result = MediaDragSelectionPolicy.selection(items: parent.items, baseline: dragBase,
        start: start, end: path.item, adding: dragAdds)
      tapGate.suppressTap()
      if result != parent.selectedIDs { parent.onSelectionChange?(result) }
    }

    @objc func scrollDuringSelection(_ link: CADisplayLink) {
      guard let view, dragStart != nil else { return }
      let top = view.contentOffset.y + view.adjustedContentInset.top
      let bottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
      let speed: CGFloat = dragPoint.y < top + 48 ? -240 : (dragPoint.y > bottom - 48 ? 240 : 0)
      let minimum = -view.adjustedContentInset.top
      let maximum = max(minimum, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
      let offset = min(max(view.contentOffset.y + speed * CGFloat(link.targetTimestamp - link.timestamp), minimum), maximum)
      dragPoint.y += offset - view.contentOffset.y
      view.contentOffset.y = offset
      updateDragSelection()
    }

    func endDragSelection() {
      dragScrollLink?.invalidate(); dragScrollLink = nil
      if dragStart != nil { tapGate.suppressTap() }
      dragStart = nil
      dragEnd = nil
      view?.panGestureRecognizer.isEnabled = true
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

    func releaseTouchOwnership() {
      tapGate.hasMultipleTouches = false
      tapGate.suppressTap()
      view?.panGestureRecognizer.isEnabled = true
      applyLatest()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === selectionDrag {
        guard parent.selectionMode, zoom.phase == .idle, let view, !tapGate.hasMultipleTouches,
          let path = view.indexPathForItem(at: gestureRecognizer.location(in: view)), path.section == 1,
          path.item < parent.items.count else { return false }
        return parent.items[path.item].isVideo
      }
      guard active, let view,
        let layout = view.collectionViewLayout as? PhotoGridLayout else { return false }
      let point = gestureRecognizer.location(in: view)
      return layout.mediaRegion.contains(point) && view.numberOfItems(inSection: 1) > 0
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      // Keep a first-finger scroll from failing the still-possible pinch.
      otherGestureRecognizer === view?.panGestureRecognizer
    }

    func startZoomClock() {
      guard zoomLink == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(advanceZoom))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(UIScreen.main.maximumFramesPerSecond), preferred: Float(UIScreen.main.maximumFramesPerSecond))
      link.add(to: .main, forMode: .common)
      zoomLink = link
    }

    func setGridInteraction(_ interacting: Bool) {
      let previous = interactionTask
      let service = parent.appState.thumbnailService, owner = interactionOwner
      interactionTask = Task {
        await previous?.value
        await service.setGridInteraction(interacting, owner: owner)
      }
    }

    func cancelZoom() {
      zoom.generation &+= 1
      zoom.phase = .idle
      pendingPinch = nil
      lastZoomTimestamp = nil
      zoomLink?.invalidate(); zoomLink = nil
      anchorID = nil
      lastWarmSignature = ""
      cancelPrefetches()
      setGridInteraction(false)
      view?.panGestureRecognizer.isEnabled = true
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard active, let view, let layout = view.collectionViewLayout as? PhotoGridLayout else { return }
      tapGate.suppressTap()
      switch recognizer.state {
      case .began:
        let point = recognizer.location(in: view)
        let path = view.indexPathsForVisibleItems.filter { $0.section == 1 }.min {
          let a = layout.layoutAttributesForItem(at: $0)?.center ?? .zero
          let b = layout.layoutAttributesForItem(at: $1)?.center ?? .zero
          return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }
        if let path, case .media(let id) = dataSource.itemIdentifier(for: path),
          let frame = layout.layoutAttributesForItem(at: path)?.frame {
          anchorID = id
          anchorFraction = CGPoint(x: min(max((point.x - frame.minX) / max(frame.width, 1), 0), 1),
                                   y: min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1))
        }
        anchorScreen = CGPoint(x: point.x - view.contentOffset.x, y: point.y - view.contentOffset.y)
        zoom.position = layout.position
        zoom.begin(widths: layout.geometry.widths)
        lastWidth = view.bounds.width
        lastWarmSignature = ""
        setGridInteraction(true)
        startZoomClock()
      case .changed, .ended:
        pendingPinch = (Double(recognizer.scale), Double(recognizer.velocity), recognizer.location(in: view))
        if recognizer.state == .ended {
          consumePinch(layout: layout, view: view)
          zoom.end()
          startZoomClock()
        }
      case .cancelled, .failed:
        pendingPinch = nil
        if zoom.phase == .tracking { zoom.end(cancelled: true); startZoomClock() }
      default: break
      }
    }

    func consumePinch(layout: PhotoGridLayout, view: UICollectionView) {
      guard let input = pendingPinch else { return }
      pendingPinch = nil
      anchorScreen = CGPoint(x: input.point.x - view.contentOffset.x, y: input.point.y - view.contentOffset.y)
      zoom.track(scale: input.scale, speed: input.velocity, widths: layout.geometry.widths)
    }

    func anchoredOffset(layout: PhotoGridLayout, view: UICollectionView) -> CGPoint {
      guard let anchorID, let path = dataSource.indexPath(for: .media(anchorID)),
        let frame = layout.layoutAttributesForItem(at: path)?.frame else { return view.contentOffset }
      let minimum = -view.adjustedContentInset.top
      let maximum = max(minimum, layout.collectionViewContentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
      let y = frame.minY + frame.height * anchorFraction.y - anchorScreen.y
      // Horizontal scrolling is constrained by the real content width. Recording
      // both fractions preserves focus; row wraps can only move within this bound.
      let xMin = -view.adjustedContentInset.left
      let xMax = max(xMin, layout.collectionViewContentSize.width - view.bounds.width + view.adjustedContentInset.right)
      let x = frame.minX + frame.width * anchorFraction.x - anchorScreen.x
      return CGPoint(x: min(max(x, xMin), xMax), y: min(max(y, minimum), maximum))
    }

    @objc func advanceZoom(_ link: CADisplayLink) {
      guard active, let view, let layout = view.collectionViewLayout as? PhotoGridLayout else { cancelZoom(); return }
      let started = ProcessInfo.processInfo.systemUptime
      let frameInterval = lastZoomTimestamp.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
      lastZoomTimestamp = link.timestamp
      if lastWidth != view.bounds.width {
        // Rotation ends the old coordinate space without waiting on UIKit callbacks.
        pendingPinch = nil; zoom.end(cancelled: true); lastWidth = view.bounds.width
      }
      consumePinch(layout: layout, view: view)
      if zoom.phase != .tracking, view.isDragging || view.isDecelerating,
        let anchorID, let path = dataSource.indexPath(for: .media(anchorID)),
        let frame = layout.layoutAttributesForItem(at: path)?.frame {
        // Adopt the pan's current viewport before advancing the zoom, so the
        // settling driver cannot pull content back against a one-finger scroll.
        anchorScreen = CGPoint(x: frame.minX + frame.width * anchorFraction.x - view.contentOffset.x,
                               y: frame.minY + frame.height * anchorFraction.y - view.contentOffset.y)
      }
      let finished = zoom.step(seconds: link.targetTimestamp - link.timestamp, reduceMotion: parent.reduceMotion)
      layout.position = zoom.position
      layout.invalidateLayout()
      let offset = anchoredOffset(layout: layout, view: view)
      UIView.performWithoutAnimation {
        view.setContentOffset(offset, animated: false)
        view.layoutIfNeeded()
      }
      warmZoomViewport(layout: layout, view: view)
      GridArtworkTrace.event("grid-frame", id: parent.resetKey,
        detail: "intervalMs=\(frameInterval * 1000) " + gridFrameDiagnostic(layout: layout, view: view), since: started)
      if finished {
        let columns = MediaGridZoomPolicy.levels[Int(zoom.target)]
        lastColumns = columns
        parent.columnCount = columns
        cancelZoom()
        applyLatest()
      }
    }

    func gridFrameDiagnostic(layout: PhotoGridLayout, view: UICollectionView) -> String {
      let expected = Set((layout.layoutAttributesForElements(in: view.bounds) ?? []).map(\.indexPath))
      let actual = Set(view.indexPathsForVisibleItems)
      let ids = actual.compactMap { path -> String? in
        guard case .media(let id) = dataSource.itemIdentifier(for: path), let item = mediaByID[id] else { return nil }
        return "\(ArtworkIdentity.digest(id).prefix(8)):\(parent.appState.thumbnailService.cachedThumbnail(for: item) != nil)"
      }.sorted()
      return "state=\(zoom.phase.rawValue) generation=\(zoom.generation) progress=\(zoom.position) offset=\(view.contentOffset) size=\(layout.collectionViewContentSize) missingCells=\(expected.subtracting(actual).count) images=\(ids)"
    }

    func warmZoomViewport(layout: PhotoGridLayout, view: UICollectionView) {
      let target = min(max(Int((zoom.position + zoom.velocity * 0.12).rounded()), 0), 4)
      let signature = "\(target)|\(Int(view.contentOffset.y / 180))"
      guard signature != lastWarmSignature else { return }
      lastWarmSignature = signature
      var predicted = layout.geometry
      predicted.position = Double(target)
      var rect = view.bounds
      if let anchorID, let path = dataSource.indexPath(for: .media(anchorID)) {
        rect.origin.y = predicted.frame(path.item).minY + predicted.frame(path.item).height * anchorFraction.y - anchorScreen.y
      }
      rect.origin.y = min(max(rect.origin.y, 0), max(0, predicted.bottom + 88 - rect.height))
      let candidates = Array(predicted.candidates(in: rect).prefix(36))
      var ids = Set(view.indexPathsForVisibleItems.compactMap { path -> String? in
        guard case .media(let id) = dataSource.itemIdentifier(for: path) else { return nil }; return id
      })
      for index in candidates {
        if case .media(let id) = dataSource.itemIdentifier(for: IndexPath(item: index, section: 1)) { ids.insert(id) }
      }
      for id in zoomWarmIDs.subtracting(ids) {
        prefetchTasks.removeValue(forKey: id)?.task.cancel()
      }
      zoomWarmIDs = ids
      let pixels = Int(PhotoGridZoomState.width(at: Double(target), widths: predicted.widths) * view.traitCollection.displayScale)
      for id in ids.prefix(48) { prefetch(id, pixels: pixels) }
    }

  }
}

/// In selection mode a held card belongs to the grid, not its hosted button.
final class LibrarySelectionRecognizer: UILongPressGestureRecognizer {
  override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
    if other is UIPinchGestureRecognizer { return true }
    if let view, let otherView = other.view, otherView.isDescendant(of: view), otherView !== view { return false }
    return super.canBePrevented(by: other)
  }
}

/// Calculate only rows intersecting the viewport, even in very large directories.
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
