import SwiftUI

struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var accessToken = CredentialStore.shared.accessToken ?? ""
  @State private var refreshToken = CredentialStore.shared.refreshToken ?? ""
  @State private var rootFolderID = ""
  @State private var statusMessage: String?
  @State private var isTesting = false

  var body: some View {
    @Bindable var appState = appState

    Form {
      Section("浏览") {
        Picker("封面列数", selection: $appState.gridColumns) {
          Text("2 列").tag(2)
          Text("3 列").tag(3)
          Text("4 列").tag(4)
        }
        Picker("默认清晰度", selection: $appState.defaultQuality) {
          ForEach(AppState.DefaultQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }
        Picker("外观", selection: $appState.colorSchemePreference) {
          ForEach(AppState.ColorSchemePreference.allCases) { scheme in
            Text(scheme.title).tag(scheme)
          }
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
            .foregroundStyle(statusMessage.contains("成功") ? .green : .red)
        }
      }

      Section("缓存") {
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

      Section("播放器") {
        LabeledContent("系统播放器", value: "AVPlayer")
        LabeledContent("VLC 原画兜底", value: VLCAvailability.isAvailable ? "已启用" : "未安装")
        Text("默认优先使用 115 的最高转码，原画失败会自动回退，避免出现只显示“加载失败”的死路。")
          .font(.footnote)
          .foregroundStyle(.secondary)
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
