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
              HStack(spacing: 12) {
                RecentThumbnail(item: entry.item)
                VStack(alignment: .leading, spacing: 6) {
                  Text(entry.item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                  HStack {
                    Text("看到 \(formatTime(entry.lastPosition))")
                    Text("·")
                    Text(entry.lastPlayedAt, style: .relative)
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .navigationTitle("最近播放")
    .toolbar {
      if !appState.libraryStore.recents.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button("清空", role: .destructive) {
            appState.libraryStore.clearRecents()
          }
        }
      }
    }
    .sheet(item: $selectedVideo) { PlayerScreen(item: $0) }
  }

  private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d", value / 60, value % 60)
  }
}

private struct RecentThumbnail: View {
  let item: CloudItem

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 9)
        .fill(.quaternary)
      if let url = item.thumbnailURL {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Image(systemName: "play.rectangle")
        }
      } else {
        Image(systemName: "play.rectangle")
      }
    }
    .frame(width: 96, height: 60)
    .clipShape(RoundedRectangle(cornerRadius: 9))
  }
}
