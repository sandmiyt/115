import SwiftUI

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var accessToken = CredentialStore.shared.accessToken ?? ""
  @State private var refreshToken = CredentialStore.shared.refreshToken ?? ""
  @State private var rootFolderID = ""
  @State private var statusMessage: String?
  @State private var isTesting = false
  @State private var isChangingFaceID = false

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

        Picker("默认浏览方式", selection: $appState.browserLayout) {
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

        Picker("缩略图显示", selection: $appState.artworkMode) {
          ForEach(AppState.ArtworkMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }

        HStack(spacing: 8) {
          Circle().fill(CinevaTheme.accentWarm).frame(width: 18, height: 18)
          Circle().fill(CinevaTheme.accent).frame(width: 18, height: 18)
          Circle().fill(CinevaTheme.accentRed).frame(width: 18, height: 18)
          Text("Cineva 影院橙")
            .font(.footnote)
            .foregroundStyle(.secondary)
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

        Toggle("播放结束自动下一集", isOn: $appState.autoPlayNextEpisode)

        LabeledContent("播放器", value: "AVPlayer")
        LabeledContent("画中画", value: "支持")
        LabeledContent("横竖屏", value: "自动适配")
        LabeledContent("VLC 原画兜底", value: VLCAvailability.isAvailable ? "已启用" : "未安装")
      }

      Section("隐私与安全") {
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

        Text(
          appState.canUseBiometrics
            ? "开启后，Cineva 从后台重新进入时会先验证身份。"
            : "当前设备未检测到可用的面容 ID / 生物识别。"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)

        if let message = appState.biometricErrorMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }

      Section("115 连接") {
        SecureField("Access Token", text: $accessToken)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField("Refresh Token", text: $refreshToken)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("根目录 ID", text: $rootFolderID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()

        Button {
          Task { await saveAndTest() }
        } label: {
          HStack {
            Text("保存并测试连接")
            Spacer()
            if isTesting { ProgressView() }
          }
        }
        .disabled(refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(statusMessage.contains("成功") || statusMessage.contains("已清除") ? .green : .red)
        }
      }

      Section("缓存与记录") {
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
        LabeledContent("版本", value: "1.4")
      }

      Section {
        Button("退出 115 授权", role: .destructive) {
          appState.signOut()
        }
      }
    }
    .navigationTitle("设置")
    .onAppear {
      rootFolderID = appState.rootFolderID
    }
  }

  @MainActor
  private func saveAndTest() async {
    isTesting = true
    defer { isTesting = false }
    CredentialStore.shared.save(
      accessToken: accessToken.isEmpty ? nil : accessToken,
      refreshToken: refreshToken
    )
    do {
      try await appState.api.validateCredentials()
      appState.rootFolderID = rootFolderID.isEmpty ? "0" : rootFolderID
      accessToken = CredentialStore.shared.accessToken ?? accessToken
      refreshToken = CredentialStore.shared.refreshToken ?? refreshToken
      statusMessage = "连接成功。"
    } catch {
      statusMessage = error.localizedDescription
    }
  }
}
