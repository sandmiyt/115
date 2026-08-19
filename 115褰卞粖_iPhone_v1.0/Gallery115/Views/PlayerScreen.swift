import SwiftUI

struct PlayerScreen: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState
  let item: CloudItem

  @State private var model: PlayerModel?
  @State private var useVLC = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ZStack {
          Color.black
          if let model {
            if useVLC, let source = model.selectedSource, source.isOriginal,
              VLCAvailability.isAvailable
            {
              VLCPlayerView(source: source)
            } else {
              SystemPlayerView(player: model.player)
            }
          } else {
            ProgressView()
              .tint(.white)
          }
        }
        .aspectRatio(16 / 9, contentMode: .fit)

        List {
          Section {
            Text(item.name)
              .font(.headline)
              .textSelection(.enabled)
            HStack {
              Label(item.formattedSize, systemImage: "externaldrive")
              Spacer()
              if !item.formattedDuration.isEmpty {
                Label(item.formattedDuration, systemImage: "clock")
              }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
          }

          if let model {
            Section("清晰度") {
              if model.isPreparing && model.sources.isEmpty {
                HStack {
                  ProgressView()
                  Text("正在取得播放地址…")
                }
              } else {
                ForEach(model.sources) { source in
                  Button {
                    Task {
                      useVLC = shouldUseVLC(source)
                      await model.select(source)
                    }
                  } label: {
                    HStack {
                      Text(source.title)
                      if source.isOriginal {
                        Text("源文件")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                      }
                      Spacer()
                      if model.selectedSource?.id == source.id {
                        Image(systemName: "checkmark")
                      }
                    }
                  }
                }
              }
            }

            if model.didFallbackFromOriginal {
              Section {
                Label(
                  "原画没有被系统播放器成功打开，已自动切换到最高可用转码。",
                  systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
              }
            }

            if item.prefersVLCForOriginal {
              Section("原画兼容") {
                if VLCAvailability.isAvailable {
                  Toggle("MKV 等格式优先使用 VLC 内核", isOn: $useVLC)
                } else {
                  Label("未安装 MobileVLCKit；系统不支持的原画会自动回退转码。", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
              }
            }

            Section {
              Button {
                appState.libraryStore.toggleFavorite(item)
              } label: {
                Label(
                  appState.libraryStore.isFavorite(item) ? "取消收藏" : "收藏这个视频",
                  systemImage: appState.libraryStore.isFavorite(item) ? "heart.slash" : "heart"
                )
              }
            }
          }
        }
        .listStyle(.insetGrouped)
      }
      .navigationTitle("播放")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("完成") {
            model?.pause()
            dismiss()
          }
        }
      }
      .alert(
        "播放失败",
        isPresented: Binding(
          get: { model?.errorMessage != nil },
          set: { if !$0 { model?.errorMessage = nil } }
        )
      ) {
        Button("知道了", role: .cancel) {}
      } message: {
        Text(model?.errorMessage ?? "未知错误")
      }
      .task {
        guard model == nil else { return }
        let newModel = PlayerModel(
          item: item,
          api: appState.api,
          libraryStore: appState.libraryStore,
          defaultQuality: appState.defaultQuality
        )
        model = newModel
        await newModel.prepareAndPlay()
        if let selected = newModel.selectedSource {
          useVLC = shouldUseVLC(selected)
        }
      }
      .onDisappear {
        model?.pause()
      }
    }
  }

  private func shouldUseVLC(_ source: VideoSource) -> Bool {
    source.isOriginal && item.prefersVLCForOriginal && VLCAvailability.isAvailable
  }
}
