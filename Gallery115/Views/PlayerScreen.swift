import SwiftUI
import UIKit

struct PlayerScreen: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState
  let item: CloudItem

  @State private var model: PlayerModel?
  @State private var useVLC = false
  @State private var showInfo = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black.ignoresSafeArea()

        playerLayer
          .frame(width: proxy.size.width, height: proxy.size.height)
          .background(Color.black)
          .ignoresSafeArea()

        VStack(spacing: 0) {
          topOverlay(proxy: proxy)
          Spacer(minLength: 0)
          bottomOverlay(proxy: proxy)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(Color.black)
    .ignoresSafeArea()
    .statusBarHidden(true)
    .sheet(isPresented: $showInfo) {
      PlayerInfoSheet(item: item, model: model)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
      PlayerOrientation.request(.portrait)
    }
  }

  @ViewBuilder
  private var playerLayer: some View {
    if let model {
      if useVLC, let source = model.selectedSource, source.isOriginal,
        VLCAvailability.isAvailable
      {
        VLCPlayerView(source: source)
      } else {
        SystemPlayerView(player: model.player)
      }
    } else {
      ZStack {
        Color.black
        ProgressView("正在准备播放…")
          .tint(.white)
          .foregroundStyle(.white.opacity(0.8))
      }
    }
  }

  private func topOverlay(proxy: GeometryProxy) -> some View {
    HStack(spacing: 10) {
      playerButton(systemName: "xmark") {
        model?.pause()
        dismiss()
      }

      Text(item.name)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .shadow(radius: 5)

      Spacer(minLength: 4)

      if let model {
        Menu {
          if model.sources.isEmpty {
            Text("正在取得清晰度…")
          } else {
            ForEach(model.sources) { source in
              Button {
                Task {
                  useVLC = shouldUseVLC(source)
                  await model.select(source)
                }
              } label: {
                if model.selectedSource?.id == source.id {
                  Label(source.title, systemImage: "checkmark")
                } else {
                  Text(source.title)
                }
              }
            }
          }
        } label: {
          playerLabel(
            systemName: "slider.horizontal.3",
            text: model.selectedSource?.title ?? "清晰度"
          )
        }
      }

      playerButton(systemName: "rectangle.landscape.rotate") {
        PlayerOrientation.toggle()
      }

      playerButton(systemName: "ellipsis") {
        showInfo = true
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, max(proxy.safeAreaInsets.top, 10))
    .padding(.bottom, 10)
    .background(
      LinearGradient(
        colors: [.black.opacity(0.72), .clear],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  @ViewBuilder
  private func bottomOverlay(proxy: GeometryProxy) -> some View {
    VStack(spacing: 10) {
      if model?.didFallbackFromOriginal == true {
        Label("原画不可播，已自动切换最高转码", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption.weight(.medium))
          .foregroundStyle(.white.opacity(0.86))
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.black.opacity(0.58), in: Capsule())
      }

      HStack(spacing: 10) {
        Button {
          appState.libraryStore.toggleFavorite(item)
        } label: {
          playerLabel(
            systemName: appState.libraryStore.isFavorite(item) ? "heart.fill" : "heart",
            text: appState.libraryStore.isFavorite(item) ? "已收藏" : "收藏"
          )
        }
        .buttonStyle(.plain)

        Spacer()

        if !item.formattedDuration.isEmpty {
          Text(item.formattedDuration)
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.72))
        }
      }
      .padding(.horizontal, 14)
      .padding(.bottom, max(proxy.safeAreaInsets.bottom, 8))
    }
    .padding(.top, 16)
    .background(
      LinearGradient(
        colors: [.clear, .black.opacity(0.64)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private func playerButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .background(.black.opacity(0.48), in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
  }

  private func playerLabel(systemName: String, text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemName)
      Text(text).lineLimit(1)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .frame(height: 38)
    .background(.black.opacity(0.48), in: Capsule())
  }

  private func shouldUseVLC(_ source: VideoSource) -> Bool {
    source.isOriginal && item.prefersVLCForOriginal && VLCAvailability.isAvailable
  }
}

private struct PlayerInfoSheet: View {
  @Environment(AppState.self) private var appState
  let item: CloudItem
  let model: PlayerModel?

  var body: some View {
    NavigationStack {
      List {
        Section("视频") {
          LabeledContent("名称", value: item.name)
          LabeledContent("大小", value: item.formattedSize)
          if !item.formattedDuration.isEmpty {
            LabeledContent("时长", value: item.formattedDuration)
          }
          if !item.fileExtension.isEmpty {
            LabeledContent("格式", value: item.fileExtension.uppercased())
          }
        }

        Section("播放") {
          LabeledContent("当前清晰度", value: model?.selectedSource?.title ?? "读取中")
          LabeledContent("播放器", value: "AVPlayer")
          LabeledContent("画中画", value: "支持")
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
      .navigationTitle("播放详情")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private enum PlayerOrientation {
  @MainActor
  static func toggle() {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    else { return }

    let current = scene.interfaceOrientation
    request(current.isPortrait ? .landscape : .portrait, scene: scene)
  }

  @MainActor
  static func request(_ orientations: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first(where: { $0.activationState == .foregroundActive })
    else { return }
    request(orientations, scene: scene)
  }

  @MainActor
  private static func request(_ orientations: UIInterfaceOrientationMask, scene: UIWindowScene) {
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    scene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
  }
}
