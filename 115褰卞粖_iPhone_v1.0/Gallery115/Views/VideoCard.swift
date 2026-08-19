import SwiftUI

struct VideoCard: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let onOpen: () -> Void

  @State private var generatedImage: UIImage?
  @State private var serverThumbnailFailed = false

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 7) {
        ZStack(alignment: .bottomTrailing) {
          thumbnail
            .aspectRatio(16 / 10, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()

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
        .clipShape(RoundedRectangle(cornerRadius: 12))

        Text(item.name)
          .font(.subheadline.weight(.medium))
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
              .foregroundStyle(.red)
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
      AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) {
        phase in
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
      Rectangle().fill(.quaternary)
      Image(systemName: "play.rectangle.fill")
        .font(.system(size: 30))
        .foregroundStyle(.secondary)
    }
  }
}
