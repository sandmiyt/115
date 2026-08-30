import SwiftUI
import UIKit

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  var transitionNamespace: Namespace.ID? = nil
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 7) {
        MediaArtworkCard(item: item, progress: resumeProgress)
          .cinevaPlayerTransitionSource(id: item.id, in: transitionNamespace)
          .overlay(alignment: .topTrailing) {
            if appState.libraryStore.isFavorite(item) {
              Image(systemName: "heart.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(.ultraThinMaterial, in: Circle())
                .background(CinevaTheme.accent.opacity(0.62), in: Circle())
                .padding(7)
            }
          }

        Text(item.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(MediaCardButtonStyle())
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

  var body: some View {
    ZStack(alignment: .bottom) {
      VideoArtwork(item: item)

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
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.primary.opacity(0.08), lineWidth: 0.6)
    }
    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
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

/// Shared 16:9 media artwork used by the file grid and home screen.
/// The frame ratio is stable, while the source image always keeps its own aspect ratio.
struct VideoArtwork: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem

  @State private var cachedImage: UIImage?
  @State private var loadedIdentity: String?
  @State private var activeRequestIdentity: String?
  @State private var isLoading = false

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
    .aspectRatio(16 / 9, contentMode: .fit)
    .task(id: itemThumbnailIdentity) {
      let identity = itemThumbnailIdentity
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
      let image = await withTaskCancellationHandler {
        await appState.thumbnailService.thumbnail(for: item, api: appState.api)
      } onCancel: {
        spinner.cancel()
      }
      guard !Task.isCancelled else { return }
      guard let image else { return }
      let shouldFadeIn = cachedImage == nil && isLoading
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
    "\(item.id)|\(item.size)"
  }

  @ViewBuilder
  private func artwork(_ image: Image, in size: CGSize) -> some View {
    switch appState.artworkMode {
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
      Image(systemName: "play.rectangle.fill")
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
    if #available(iOS 18.0, *) {
      navigationTransition(.zoom(sourceID: sourceID, in: namespace))
    } else {
      self
    }
  }
}

private struct MediaCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.90 : 1)
      .animation(.spring(response: 0.24, dampingFraction: 0.86), value: configuration.isPressed)
  }
}
