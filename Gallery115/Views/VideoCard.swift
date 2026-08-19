import SwiftUI

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let onOpen: () -> Void

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 5) {
        ZStack(alignment: .bottom) {
          VideoArtwork(item: item)

          LinearGradient(
            colors: [.clear, .black.opacity(0.34)],
            startPoint: .center,
            endPoint: .bottom
          )
          .allowsHitTesting(false)

          HStack(alignment: .bottom) {
            if !item.fileExtension.isEmpty {
              Text(item.fileExtension.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.58), in: Capsule())
            }

            Spacer(minLength: 6)

            if !item.formattedDuration.isEmpty {
              Text(item.formattedDuration)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.72), in: Capsule())
            }
          }
          .padding(6)

          if resumeProgress > 0.002 {
            GeometryReader { proxy in
              VStack(spacing: 0) {
                Spacer()
                ZStack(alignment: .leading) {
                  Rectangle().fill(.white.opacity(0.24))
                  Rectangle()
                    .fill(CinevaTheme.accent)
                    .frame(width: max(2, proxy.size.width * resumeProgress))
                }
                .frame(height: 3)
              }
            }
            .allowsHitTesting(false)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.primary.opacity(0.08), lineWidth: 0.6)
        }

        Text(item.name)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)

        HStack(spacing: 5) {
          Text(item.formattedSize)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 2)
          if appState.libraryStore.isFavorite(item) {
            Image(systemName: "heart.fill")
              .font(.caption2)
              .foregroundStyle(CinevaTheme.accent)
          }
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        appState.libraryStore.toggleFavorite(item)
      } label: {
        Label(
          appState.libraryStore.isFavorite(item) ? "取消收藏" : "收藏",
          systemImage: appState.libraryStore.isFavorite(item) ? "heart.slash" : "heart"
        )
      }
    }
  }

  private var resumeProgress: Double {
    guard item.duration > 0 else { return 0 }
    let position = appState.libraryStore.resumePosition(for: item)
    guard position > 2, position < item.duration - 8 else { return 0 }
    return min(max(position / item.duration, 0), 1)
  }
}

/// Shared 16:9 media artwork used by the file grid and home screen.
/// The frame ratio is stable, while the source image always keeps its own aspect ratio.
struct VideoArtwork: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem

  @State private var generatedImage: UIImage?
  @State private var serverThumbnailFailed = false

  var body: some View {
    ZStack {
      artworkBackground

      if let generatedImage {
        artwork(Image(uiImage: generatedImage))
      } else if let url = item.thumbnailURL, !serverThumbnailFailed {
        AsyncImage(
          url: url,
          transaction: Transaction(animation: .easeInOut(duration: 0.16))
        ) { phase in
          switch phase {
          case .success(let image):
            artwork(image)
          case .failure:
            placeholder
              .onAppear { serverThumbnailFailed = true }
          case .empty:
            ZStack {
              placeholder
              ProgressView().controlSize(.small)
            }
          @unknown default:
            placeholder
          }
        }
      } else {
        placeholder
          .task {
            if generatedImage == nil {
              generatedImage = await appState.thumbnailService.generatedThumbnail(
                for: item,
                api: appState.api
              )
            }
          }
      }
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipped()
    .task(id: item.id) {
      if item.thumbnailURL == nil, generatedImage == nil {
        generatedImage = await appState.thumbnailService.generatedThumbnail(
          for: item,
          api: appState.api
        )
      }
    }
  }

  @ViewBuilder
  private func artwork(_ image: Image) -> some View {
    switch appState.artworkMode {
    case .fit:
      ZStack {
        image
          .resizable()
          .scaledToFill()
          .blur(radius: 18)
          .opacity(0.38)
          .clipped()
        image
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .fill:
      image
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
