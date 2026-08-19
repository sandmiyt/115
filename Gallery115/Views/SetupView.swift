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
      ScrollView {
        VStack(spacing: 26) {
          brandHeader

          VStack(spacing: 14) {
            tokenField(title: "Access Token（可留空）", text: $accessToken)
            tokenField(title: "Refresh Token（必填）", text: $refreshToken)

            VStack(alignment: .leading, spacing: 7) {
              Text("根目录 ID")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              TextField("0", text: $rootFolderID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
          }

          Button {
            Task { await validateAndSave() }
          } label: {
            HStack {
              Spacer()
              if isValidating {
                ProgressView().tint(.white)
              } else {
                Label("连接 115 并进入 Cineva", systemImage: "arrow.right")
                  .fontWeight(.semibold)
              }
              Spacer()
            }
            .frame(height: 54)
            .foregroundStyle(.white)
            .background(CinevaTheme.brandGradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
          }
          .disabled(refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
          .opacity(refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)

          Label("Token 仅保存在本机 Keychain", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 38)
      }
      .navigationBarHidden(true)
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

  private var brandHeader: some View {
    VStack(spacing: 15) {
      CinevaLogoMark(size: 98)
      Text("Cineva")
        .font(.system(size: 40, weight: .bold, design: .rounded))
      Text("你的私人云端影音库")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("让 115 网盘中的视频拥有更接近专业播放器的浏览、播放和隐私体验。")
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }
  }

  private func tokenField(title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      SecureField(title, text: text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
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
