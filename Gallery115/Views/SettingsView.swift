import SwiftUI

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var statusMessage: String?
  @State private var isCheckingConnection = false
  @State private var isChangingFaceID = false
  @State private var showDisconnectConfirmation = false
  @State private var showClearRecentsConfirmation = false
  @State private var showMediaSetup = false

  var body: some View {
    @Bindable var appState = appState

    Form {
      Section("媒体源") {
        connectionSummary

        if appState.isConfigured {
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

          Button {
            showMediaSetup = true
          } label: {
            Label("重新授权 / 更换 115 账号", systemImage: "externaldrive.badge.plus")
          }

          Button("断开媒体源", role: .destructive) {
            showDisconnectConfirmation = true
          }
        } else {
          Button {
            showMediaSetup = true
          } label: {
            Label("连接 115 网盘", systemImage: "externaldrive.badge.plus")
          }
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(statusMessage.contains("正常") ? .green : .secondary)
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
          LabeledContent("封面列数") {
            Menu {
              ForEach([2, 3, 4], id: \.self) { count in
                Button {
                  setGridColumnsSafely(count)
                } label: {
                  if appState.gridColumns == count {
                    Label("\(count) 列", systemImage: "checkmark")
                  } else {
                    Text("\(count) 列")
                  }
                }
              }
            } label: {
              Text("\(min(max(appState.gridColumns, 2), 4)) 列")
            }
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
          showClearRecentsConfirmation = true
        }
      }

      Section("关于") {
        HStack(spacing: 12) {
          CinevaLogoMark(size: 42)
          VStack(alignment: .leading, spacing: 2) {
            Text("Cineva").font(.headline)
            Text("115 私人影音播放器")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent("版本", value: "2.2.0")
        LabeledContent("当前媒体源", value: appState.isConfigured ? appState.mediaSourceKind.title : "未连接")
      }
    }
    .sheet(isPresented: $showMediaSetup) {
      SetupView()
    }
    .confirmationDialog("断开当前媒体源？", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
      Button("断开媒体源", role: .destructive) {
        appState.signOut()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只会移除 Cineva 中保存的当前授权，不会删除 115 网盘中的任何文件。")
    }
    .confirmationDialog("清除全部最近播放？", isPresented: $showClearRecentsConfirmation, titleVisibility: .visible) {
      Button("清除播放记录", role: .destructive) {
        appState.libraryStore.clearRecents()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("只清除 Cineva 本地播放历史，不会删除服务器文件。")
    }
    .navigationTitle("设置")
  }

  @MainActor
  private func setGridColumnsSafely(_ value: Int) {
    let clamped = min(max(value, 2), 4)
    guard clamped != appState.gridColumns else { return }
    Task { @MainActor in
      await Task.yield()
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        appState.gridColumns = clamped
      }
    }
  }

  @ViewBuilder
  private var connectionSummary: some View {
    if appState.isConfigured {
      switch appState.mediaSourceKind {
      case .cloud115:
        HStack(spacing: 11) {
          Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.green)

          VStack(alignment: .leading, spacing: 3) {
            Text("115 网盘已授权")
              .font(.subheadline.weight(.semibold))
            Text("当前设备使用用户本人授权的 115 网盘")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        LabeledContent("读取方式", value: "115 Open API")
        Text("访问凭据保存在本机 Keychain。Cineva 会在需要时自动刷新登录状态；网络波动、限流和服务端临时错误不会自动清除授权。")
          .font(.caption)
          .foregroundStyle(.secondary)

      case .webDAV:
        if let configuration = WebDAVCredentialStore.shared.configuration {
          HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
              Text("OpenList / AList 已连接")
                .font(.subheadline.weight(.semibold))
              Text("媒体库：\(configuration.normalizedRootPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          LabeledContent("读取方式", value: "WebDAV 只读")
          if configuration.normalizedWebDAVURL?.scheme?.lowercased() == "http" {
            Label("当前连接使用 HTTP。若要使用 HTTPS，必须先在 OpenList 所在服务器或反向代理真正配置 TLS 和有效证书；仅把 http 改成 https 会直接导致 TLS 连接失败。使用 IP+端口时，证书还必须与该访问地址匹配。", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Text("服务器地址与账号信息不会在设置页展示。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      Label("尚未连接 115 网盘。", systemImage: "externaldrive.badge.xmark")
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
          statusMessage = "\(appState.mediaSourceKind.title)连接正常。"
          appState.markMediaConnected()
          isCheckingConnection = false
        }
      } catch {
        await MainActor.run {
          statusMessage = error.localizedDescription
          appState.markMediaOffline()
          isCheckingConnection = false
        }
      }
    }
  }
}
