import SwiftUI
import UIKit

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  var transitionNamespace: Namespace.ID? = nil
  var compact = false
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 7) {
        MediaArtworkCard(item: item, progress: resumeProgress, compact: compact)
          .cinevaPlayerTransitionSource(id: item.id, in: transitionNamespace)
          .overlay(alignment: .topTrailing) {
            if appState.libraryStore.isFavorite(item) {
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
    .accessibilityLabel(item.name)
    .accessibilityHint(item.isPhoto ? "查看照片预览" : "播放视频")
    .contextMenu {
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
  @State private var loadFailed = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        artworkBackground
          .frame(width: proxy.size.width, height: proxy.size.height)

        if let cachedImage {
          artwork(Image(uiImage: cachedImage), in: proxy.size)
            .transition(.opacity)
        } else {
          ZStack {
            placeholder
            if loadFailed {
              Text("暂无缩略图").font(.caption2).foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 6)
            }
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
    .task(id: "\(itemThumbnailIdentity)|\(artworkRefreshRevision)") {
      let identity = itemThumbnailIdentity
      if renderedItemIdentity != identity {
        cachedImage = nil
        renderedItemIdentity = identity
      }
      if loadedIdentity == identity, cachedImage != nil { return }
      loadFailed = false
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
      let image = await withTaskCancellationHandler {
        var result: UIImage?
        for attempt in 0..<3 {
          if attempt > 0 {
            do { try await Task.sleep(nanoseconds: 6_000_000_000) }
            catch { return nil as UIImage? }
          }
          guard !Task.isCancelled else { return nil as UIImage? }
          result = await appState.thumbnailService.thumbnail(for: item, api: appState.api)
          if result != nil { break }
        }
        return result
      } onCancel: {
        spinner.cancel()
      }
      guard !Task.isCancelled else { return }
      guard let image else { loadFailed = true; return }
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
