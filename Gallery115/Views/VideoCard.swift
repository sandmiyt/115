import SwiftUI

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let onOpen: () -> Void

  @State private var generatedImage: UIImage?
  @State private var serverThumbnailFailed = false

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .bottomTrailing) {
          thumbnail
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()

          LinearGradient(
            colors: [.clear, .black.opacity(0.34)],
            startPoint: .center,
            endPoint: .bottom
          )
          .allowsHitTesting(false)

          if !item.formattedDuration.isEmpty {
            Text(item.formattedDuration)
              .font(.caption2.monospacedDigit().weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.black.opacity(0.72), in: Capsule())
              .padding(6)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(.primary.opacity(0.06), lineWidth: 0.5)
        }

        Text(item.name)
          .font(.subheadline.weight(.semibold))
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
              .foregroundStyle(.pink)
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
    .task(id: item.id) {
      if item.thumbnailURL == nil {
        generatedImage = await appState.thumbnailService.generatedThumbnail(
          for: item, api: appState.api)
      }
    }
  }

  @ViewBuilder
  private var thumbnail: some View {
    if let generatedImage {
      Image(uiImage: generatedImage)
        .resizable()
    } else if let url = item.thumbnailURL, !serverThumbnailFailed {
      AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
        switch phase {
        case .success(let image):
          image.resizable()
        case .failure:
          placeholder
            .onAppear { serverThumbnailFailed = true }
        case .empty:
          ZStack {
            placeholder
            ProgressView()
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
              for: item, api: appState.api)
          }
        }
    }
  }

  private var placeholder: some View {
    ZStack {
      Rectangle().fill(.secondary.opacity(0.10))
      Image(systemName: "play.rectangle.fill")
        .font(.system(size: 30))
        .foregroundStyle(.secondary)
    }
  }
}
