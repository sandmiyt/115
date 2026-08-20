import SwiftUI

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var statusMessage: String?
  @State private var isCheckingConnection = false
  @State private var isChangingFaceID = false

  var body: some View {
    @Bindable var appState = appState

    Form {
      Section("媒体源") {
        connectionSummary

        Button(action: checkConnection) {
          HStack {
            Label("检查连接", systemImage: "wave.3.right.circle")
            Spacer()
            if isCheckingConnection {
              ProgressView()
            }
          }
        }
        .disabled(isCheckingConnection)

        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(statusMessage.contains("正常") ? .green : .secondary)
        }

        Button("更换或断开媒体源", role: .destructive) {
          appState.signOut()
        }
      }

      Section("外观") {
        Picker("界面", selection: $appState.colorSchemePreference) {
          ForEach(AppState.ColorSchemePreference.allCases) { scheme in
            Text(scheme.title).tag(scheme)
          }
        }
        .pickerStyle(.segmented)

        Picker("浏览方式", selection: $appState.browserLayout) {
          ForEach(AppState.BrowserLayout.allCases) { layout in
            Label(layout.title, systemImage: layout.icon).tag(layout)
          }
        }

        if appState.browserLayout == .grid {
          Picker("封面列数", selection: $appState.gridColumns) {
            Text("2 列").tag(2)
            Text("3 列").tag(3)
            Text("4 列").tag(4)
          }
        }

        Picker("缩略图", selection: $appState.artworkMode) {
          ForEach(AppState.ArtworkMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
      }

      Section("播放") {
        Toggle("播放器手势", isOn: $appState.playerGesturesEnabled)

        if appState.playerGesturesEnabled {
          Picker("双击快进/快退", selection: $appState.doubleTapSeekSeconds) {
            Text("10 秒").tag(10)
            Text("15 秒").tag(15)
            Text("30 秒").tag(30)
          }
        }

        Toggle("自动播放下一集", isOn: $appState.autoPlayNextEpisode)
        Text(
          appState.autoPlayNextEpisode
            ? "有下一集时自动播放下一集；最后一个视频自动重播。"
            : "关闭后，当前视频播放结束会自动从头重播。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("隐私") {
        Toggle(
          "\(appState.biometricTitle)进入验证",
          isOn: Binding(
            get: { appState.faceIDEnabled },
            set: { newValue in
              guard !isChangingFaceID else { return }
              isChangingFaceID = true
              Task {
                _ = await appState.setFaceIDProtection(newValue)
                isChangingFaceID = false
              }
            }
          )
        )
        .disabled(isChangingFaceID || (!appState.canUseBiometrics && !appState.faceIDEnabled))

        if let message = appState.biometricErrorMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }

      Section("缓存") {
        Button("清除资料库缓存") {
          Task {
            await appState.api.clearMountCache()
            await MainActor.run {
              statusMessage = "资料库缓存已清除，下次进入目录会重新读取服务器。"
            }
          }
        }

        Button("清除封面缓存") {
          Task {
            await appState.thumbnailService.clearCache()
            await MainActor.run { statusMessage = "封面缓存已清除。" }
          }
        }

        Button("清除最近播放") {
          appState.libraryStore.clearRecents()
        }
      }

      Section("关于") {
        HStack(spacing: 12) {
          CinevaLogoMark(size: 42)
          VStack(alignment: .leading, spacing: 2) {
            Text("Cineva").font(.headline)
            Text("OpenList / AList 私人影音播放器")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent("版本", value: "2.0")
        LabeledContent("挂载协议", value: "WebDAV")
      }
    }
    .navigationTitle("设置")
  }

  @ViewBuilder
  private var connectionSummary: some View {
    if let configuration = WebDAVCredentialStore.shared.configuration {
      HStack(spacing: 11) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)

        VStack(alignment: .leading, spacing: 3) {
          Text("OpenList / AList 已连接")
            .font(.subheadline.weight(.semibold))
          Text(configuration.normalizedWebDAVURL?.host ?? configuration.serverURL)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text("媒体库：\(configuration.normalizedRootPath)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      LabeledContent("读取方式", value: "WebDAV 只读")
      Text("115 Token、刷新、限流与 405 均由 OpenList / AList 服务器端处理；Cineva 不直接访问 115 Open API。")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Label("未连接媒体源", systemImage: "externaldrive.badge.xmark")
        .foregroundStyle(.secondary)
    }
  }

  private func checkConnection() {
    guard !isCheckingConnection else { return }
    isCheckingConnection = true
    statusMessage = nil
    Task {
      do {
        try await appState.api.validateCredentials()
        await MainActor.run {
          statusMessage = "OpenList / AList 连接正常。"
          isCheckingConnection = false
        }
      } catch {
        await MainActor.run {
          statusMessage = error.localizedDescription
          isCheckingConnection = false
        }
      }
    }
  }
}
