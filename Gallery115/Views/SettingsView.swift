import SwiftUI

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var authorizationSession: Cloud115AuthorizationSession?
  @State private var statusMessage: String?
  @State private var isConnecting = false
  @State private var isChangingFaceID = false
  @State private var showAdvanced = false
  @State private var rootFolderID = "0"

  var body: some View {
    @Bindable var appState = appState

    Form {
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
        Picker("默认清晰度", selection: $appState.defaultQuality) {
          ForEach(AppState.DefaultQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }

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
            ? "开启：优先播放下一集；已经是最后一个视频时自动重播。"
            : "关闭：当前视频播放结束后自动从头重播。"
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

      Section("115 网盘") {
        HStack(spacing: 10) {
          Image(systemName: CredentialStore.shared.hasRefreshToken ? "checkmark.circle.fill" : "externaldrive.badge.icloud")
            .foregroundStyle(CredentialStore.shared.hasRefreshToken ? .green : CinevaTheme.accent)
          VStack(alignment: .leading, spacing: 2) {
            Text(CredentialStore.shared.hasRefreshToken ? "115 已连接" : "未连接 115")
              .font(.subheadline.weight(.semibold))
            Text("登录凭据由 Cineva 自动获取并保存在本机 Keychain")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Button(action: connect115) {
          HStack {
            Text(CredentialStore.shared.hasRefreshToken ? "检查连接" : "连接 115 网盘")
            Spacer()
            if isConnecting {
              ProgressView()
            } else {
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
        }
        .disabled(isConnecting)

        DisclosureGroup("高级", isExpanded: $showAdvanced) {
          TextField("根目录 ID", text: $rootFolderID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit {
              appState.rootFolderID = rootFolderID.isEmpty ? "0" : rootFolderID
            }

          Text("默认 0 表示整个 115 网盘。通常无需修改。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(statusMessage.contains("成功") || statusMessage.contains("正常") ? .green : .red)
        }

        if CredentialStore.shared.hasRefreshToken {
          Button("断开 115", role: .destructive) {
            appState.signOut()
          }
        }
      }

      Section("数据") {
        Button("清除封面缓存") {
          Task {
            await appState.thumbnailService.clearCache()
            statusMessage = "封面缓存已清除。"
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
            Text("115 云端影音播放器").font(.caption).foregroundStyle(.secondary)
          }
        }
        LabeledContent("版本", value: "1.5")
      }
    }
    .navigationTitle("设置")
    .onAppear {
      rootFolderID = appState.rootFolderID
    }
    .sheet(item: $authorizationSession) { session in
      Cloud115AuthorizationSheet(session: session) { result in
        authorizationSession = nil
        handleAuthorizationResult(result)
      }
    }
  }

  private func connect115() {
    guard !isConnecting else { return }
    isConnecting = true
    statusMessage = nil

    Task {
      if CredentialStore.shared.hasRefreshToken {
        do {
          try await appState.api.validateCredentials()
          await MainActor.run {
            statusMessage = "115 连接正常。"
            isConnecting = false
          }
          return
        } catch {
          // Existing refresh token can no longer recover the session; fall through to login.
        }
      }

      do {
        let session = try await Cloud115AuthorizationClient.makeSession()
        await MainActor.run {
          authorizationSession = session
          isConnecting = false
        }
      } catch {
        await MainActor.run {
          statusMessage = error.localizedDescription
          isConnecting = false
        }
      }
    }
  }

  private func handleAuthorizationResult(_ result: Result<Cloud115Credentials, Error>) {
    switch result {
    case .failure(let error):
      if !(error is CancellationError) {
        statusMessage = error.localizedDescription
      }
    case .success(let credentials):
      isConnecting = true
      CredentialStore.shared.save(
        accessToken: credentials.accessToken,
        refreshToken: credentials.refreshToken
      )
      Task {
        do {
          try await appState.api.validateCredentials()
          await MainActor.run {
            statusMessage = "115 连接成功。"
            isConnecting = false
          }
        } catch {
          await MainActor.run {
            statusMessage = error.localizedDescription
            isConnecting = false
          }
        }
      }
    }
  }
}
