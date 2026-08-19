import SwiftUI

struct RecentView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?

  var body: some View {
    Group {
      if appState.libraryStore.recents.isEmpty {
        ContentUnavailableView(
          "暂无播放记录",
          systemImage: "clock",
          description: Text("开始播放视频后会自动记录进度。")
        )
      } else {
        List {
          ForEach(appState.libraryStore.recents) { entry in
            Button {
              selectedVideo = entry.item
            } label: {
              HStack(spacing: 13) {
                RecentThumbnail(entry: entry)

                VStack(alignment: .leading, spacing: 7) {
                  Text(entry.item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                  HStack(spacing: 5) {
                    Text("看到 \(formatTime(entry.lastPosition))")
                    Text("·")
                    Text(entry.lastPlayedAt, style: .relative)
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle("最近播放")
    .toolbar {
      if !appState.libraryStore.recents.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("清空播放记录", role: .destructive) {
              appState.libraryStore.clearRecents()
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
    }
    .fullScreenCover(item: $selectedVideo) { PlayerScreen(item: $0) }
  }

  private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let secs = value % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%02d:%02d", minutes, secs)
  }
}

private struct RecentThumbnail: View {
  let entry: PlaybackEntry

  private var progress: Double {
    guard entry.item.duration > 0 else { return 0 }
    return min(max(entry.lastPosition / entry.item.duration, 0), 1)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.secondary.opacity(0.10))
        if let url = entry.item.thumbnailURL {
          AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Image(systemName: "play.rectangle.fill")
              .foregroundStyle(.secondary)
          }
        } else {
          Image(systemName: "play.rectangle.fill")
            .foregroundStyle(.secondary)
        }
      }

      GeometryReader { proxy in
        VStack {
          Spacer()
          ZStack(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.38))
            Rectangle().fill(.purple).frame(width: proxy.size.width * progress)
          }
          .frame(height: 3)
        }
      }
    }
    .frame(width: 112, height: 63)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
