import SwiftUI
import UIKit

struct RecentView: View {
  @Environment(AppState.self) private var appState
  @State private var selectedVideo: CloudItem?
  @State private var showClearConfirmation = false

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
              UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65)
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
              .padding(12)
              .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
              )
            }
            .buttonStyle(RecentRowButtonStyle())
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
      }
    }
    .navigationTitle("最近播放")
    .toolbar {
      if !appState.libraryStore.recents.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("清空播放记录", role: .destructive) {
              showClearConfirmation = true
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
    }
    .fullScreenCover(item: $selectedVideo) { PlayerScreen(item: $0) }
    .confirmationDialog("清空全部播放记录？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
      Button("清空播放记录", role: .destructive) {
        appState.libraryStore.clearRecents()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("此操作只清除 Cineva 本地播放历史，不会删除服务器文件。")
    }
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

private struct RecentRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.988 : 1)
      .opacity(configuration.isPressed ? 0.88 : 1)
      .animation(.spring(response: 0.24, dampingFraction: 0.86), value: configuration.isPressed)
  }
}

private struct RecentThumbnail: View {
  let entry: PlaybackEntry

  private var progress: Double {
    guard entry.effectiveDuration > 0 else { return 0 }
    return min(max(entry.lastPosition / entry.effectiveDuration, 0), 1)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      VideoArtwork(item: entry.item)

      GeometryReader { proxy in
        VStack(spacing: 0) {
          Spacer()
          ZStack(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.34))
            Rectangle()
              .fill(CinevaTheme.accent)
              .frame(width: proxy.size.width * progress)
          }
          .frame(height: 3)
        }
      }
    }
    .frame(width: 112, height: 63)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}
