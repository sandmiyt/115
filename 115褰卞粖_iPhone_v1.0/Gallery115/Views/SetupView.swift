import SwiftUI

struct SetupView: View {
  @Environment(AppState.self) private var appState
  @State private var accessToken = ""
  @State private var refreshToken = ""
  @State private var rootFolderID = "0"
  @State private var isValidating = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "play.rectangle.on.rectangle.fill")
              .font(.system(size: 42))
              .foregroundStyle(.tint)
            Text("115影廊")
              .font(.largeTitle.bold())
            Text("直接连接 115 Open API，在 iPhone 上用封面墙浏览和播放你的网盘视频。")
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        }

        Section("115 Token") {
          SecureField("Access Token（可留空）", text: $accessToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Refresh Token（必填）", text: $refreshToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          TextField("根目录 ID", text: $rootFolderID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Text("根目录默认填 0。Token 仅保存在本机 Keychain。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section {
          Button {
            Task { await validateAndSave() }
          } label: {
            HStack {
              Spacer()
              if isValidating {
                ProgressView()
              } else {
                Text("验证并进入")
                  .fontWeight(.semibold)
              }
              Spacer()
            }
          }
          .disabled(
            refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
        }
      }
      .navigationTitle("首次设置")
      .alert(
        "连接失败",
        isPresented: Binding(
          get: { errorMessage != nil },
          set: { if !$0 { errorMessage = nil } }
        )
      ) {
        Button("知道了", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "未知错误")
      }
    }
  }

  @MainActor
  private func validateAndSave() async {
    isValidating = true
    defer { isValidating = false }

    CredentialStore.shared.save(
      accessToken: accessToken.isEmpty ? nil : accessToken,
      refreshToken: refreshToken
    )

    do {
      try await appState.api.validateCredentials()
      appState.finishConfiguration(rootFolderID: rootFolderID)
    } catch {
      CredentialStore.shared.clear()
      errorMessage = error.localizedDescription
    }
  }
}
