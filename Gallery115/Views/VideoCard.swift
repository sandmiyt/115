import SwiftUI
import UIKit

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

/// Keep media identities alive while pinching; reflow only once the gesture ends.
struct PinchMediaGrid<Cell: View, Footer: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let items: [CloudItem]
  @Binding var columnCount: Int
  let compact: Bool
  private let cell: (CloudItem) -> Cell
  private let footer: () -> Footer
  @State private var tapGate = MediaGridTapGate()

  init(items: [CloudItem], columnCount: Binding<Int>, compact: Bool,
       @ViewBuilder cell: @escaping (CloudItem) -> Cell,
       @ViewBuilder footer: @escaping () -> Footer) {
    self.items = items
    self._columnCount = columnCount
    self.compact = compact
    self.cell = cell
    self.footer = footer
  }

  private var safeColumns: Int { MediaGridZoomPolicy.normalized(columnCount) }

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0),
      spacing: compact ? 2 : 9, alignment: .top), count: safeColumns), spacing: compact ? 2 : 11) {
      Section {
        ForEach(items) { item in cell(item) }
      } footer: {
        footer()
      }
    }
    .scrollTargetLayout()
    .padding(.horizontal, compact ? 2 : 10)
    .environment(\.mediaGridTapGate, tapGate)
    .modifier(MediaGridPinchModifier(columnCount: $columnCount, tapGate: tapGate))
    .sensoryFeedback(.selection, trigger: safeColumns)
    .accessibilityAction(named: Text("放大缩略图")) {
      columnCount = MediaGridZoomPolicy.targetColumns(from: safeColumns, magnification: 1.2)
    }
    .accessibilityAction(named: Text("缩小缩略图")) {
      columnCount = MediaGridZoomPolicy.targetColumns(from: safeColumns, magnification: 0.8)
    }
  }
}

/// A reference gate avoids invalidating every card on each gesture sample.
private final class MediaGridTapGate {
  var blockedUntil: TimeInterval = 0
  var allowsTap: Bool { ProcessInfo.processInfo.systemUptime >= blockedUntil }
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

/// Gesture samples update the transform wrapper, not the grid's cell builder.
private struct MediaGridPinchModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var columnCount: Int
  let tapGate: MediaGridTapGate
  @State private var scale: CGFloat = 1
  @State private var anchor: UnitPoint = .center
  @State private var startColumns = 3
  @State private var tracking = false
  @State private var settleTask: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .scaleEffect(max(scale, 1), anchor: UnitPoint(x: 0.5, y: min(max(anchor.y, 0), 1)))
      .background(
        LibraryPinchRecognizer(onChanged: { magnification, touchAnchor in
          tapGate.suppressTap()
          if !tracking {
            settleTask?.cancel()
            settleTask = nil
            tracking = true
            startColumns = MediaGridZoomPolicy.normalized(columnCount)
            anchor = touchAnchor
          }
          var transaction = Transaction(animation: nil)
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            scale = CGFloat(MediaGridZoomPolicy.liveScale(Double(magnification)))
          }
        }, onEnded: { magnification, cancelled in
          tapGate.suppressTap()
          tracking = false
          if !cancelled {
            let target = MediaGridZoomPolicy.targetColumns(from: startColumns,
              magnification: Double(magnification))
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
              scale = CGFloat(MediaGridZoomPolicy.handoffScale(Double(scale), from: startColumns, to: target))
              columnCount = target
            }
          }
          settle()
        })
      )
      .onDisappear {
        settleTask?.cancel()
        settleTask = nil
        tracking = false
        scale = 1
      }
  }

  private func settle() {
    settleTask?.cancel()
    settleTask = Task { @MainActor in
      // Let SwiftUI install the compensated layout before starting the spring.
      do { try await Task.sleep(nanoseconds: 16_000_000) }
      catch { return }
      guard !Task.isCancelled, !tracking else { return }
      withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.92)) {
        scale = 1
      }
      settleTask = nil
    }
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

/// Attach to the actual scroll view so two-finger pinch and one-finger pan have
/// explicit ownership. Never leave scrolling disabled while a gesture is active.
private struct LibraryPinchRecognizer: UIViewRepresentable {
  let onChanged: (CGFloat, UnitPoint) -> Void
  let onEnded: (CGFloat, Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
  func makeUIView(context: Context) -> ProbeView {
    let view = ProbeView()
    view.isUserInteractionEnabled = false
    view.onHierarchyChange = { [weak coordinator = context.coordinator] view in coordinator?.attach(view) }
    return view
  }
  func updateUIView(_ uiView: ProbeView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.attach(uiView)
  }
  static func dismantleUIView(_ uiView: ProbeView, coordinator: Coordinator) { coordinator.detach() }

  final class ProbeView: UIView {
    var onHierarchyChange: ((UIView) -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); onHierarchyChange?(self) }
    override func layoutSubviews() { super.layoutSubviews(); onHierarchyChange?(self) }
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var parent: LibraryPinchRecognizer
    weak var scrollView: UIScrollView?
    weak var probe: UIView?
    var originalMaximumTouches = 1
    var startAnchor = UnitPoint.center
    lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

    init(parent: LibraryPinchRecognizer) { self.parent = parent }

    func attach(_ view: UIView) {
      guard view.window != nil else { detach(); return }
      var ancestor = view.superview
      while let candidate = ancestor, !(candidate is UIScrollView) { ancestor = candidate.superview }
      guard let scroll = ancestor as? UIScrollView else { return }
      guard scrollView !== scroll else { return }
      detach()
      probe = view
      scrollView = scroll
      originalMaximumTouches = scroll.panGestureRecognizer.maximumNumberOfTouches
      scroll.panGestureRecognizer.maximumNumberOfTouches = 1
      pinch.delegate = self
      pinch.cancelsTouchesInView = true
      scroll.addGestureRecognizer(pinch)
    }

    func detach() {
      let scroll = scrollView
      scrollView = nil
      probe = nil
      if let scroll {
        scroll.removeGestureRecognizer(pinch)
        scroll.panGestureRecognizer.maximumNumberOfTouches = originalMaximumTouches
      }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let probe, probe.bounds.width > 0, probe.bounds.height > 0 else { return false }
      return probe.bounds.contains(gestureRecognizer.location(in: probe))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
      otherGestureRecognizer === scrollView?.panGestureRecognizer
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard scrollView != nil, probe?.window != nil else { return }
      switch recognizer.state {
      case .began:
        if let probe {
          let point = recognizer.location(in: probe)
          startAnchor = UnitPoint(x: min(max(point.x / max(probe.bounds.width, 1), 0), 1),
                                  y: min(max(point.y / max(probe.bounds.height, 1), 0), 1))
        }
        if let pan = scrollView?.panGestureRecognizer {
          pan.isEnabled = false
          pan.isEnabled = true
        }
        parent.onChanged(recognizer.scale, startAnchor)
      case .changed: parent.onChanged(recognizer.scale, startAnchor)
      case .ended: parent.onEnded(recognizer.scale, false)
      case .cancelled, .failed: parent.onEnded(recognizer.scale, true)
      default: break
      }
    }
  }
}
