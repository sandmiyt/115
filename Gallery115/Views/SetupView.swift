import SwiftUI

struct SetupView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState

  @State private var serverURL = ""
  @State private var username = ""
  @State private var password = ""
  @State private var rootPath = "/115"
  @State private var isConnecting = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 26) {
          Spacer(minLength: 20)

          VStack(spacing: 14) {
            CinevaLogoMark(size: 94)
            VStack(spacing: 6) {
              Text("Cineva")
                .font(.system(size: 38, weight: .bold, design: .rounded))
              Text("连接一次，长期稳定挂载")
                .font(.headline)
                .foregroundStyle(.secondary)
            }

            Text("Cineva 通过 OpenList / AList WebDAV 读取媒体。115 登录、Token 刷新、限流和接口变化都由服务器处理，iPhone 不再直接请求 115。")
              .font(.subheadline)
              .multilineTextAlignment(.center)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
          }

          VStack(spacing: 12) {
            setupField(title: "OpenList / AList 地址", icon: "server.rack") {
              TextField("https://pan.example.com", text: $serverURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            }

            setupField(title: "WebDAV 用户名", icon: "person.fill") {
              TextField("可留空", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            setupField(title: "WebDAV 密码", icon: "key.fill") {
              SecureField("可留空", text: $password)
            }

            setupField(title: "媒体库路径", icon: "folder.fill") {
              TextField("/115", text: $rootPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
          }

          Button(action: connect) {
            HStack(spacing: 9) {
              if isConnecting {
                ProgressView().tint(.white)
              } else {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                Text("连接媒体库").fontWeight(.semibold)
              }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(.white)
            .background(
              CinevaTheme.brandGradient,
              in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
          }
          .buttonStyle(.plain)
          .disabled(isConnecting || serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          VStack(spacing: 6) {
            Label("服务器地址会自动补齐 /dav/", systemImage: "checkmark.shield.fill")
            Text("每台设备可在进入 Cineva 后自行连接自己的 OpenList / AList；建议创建只读 WebDAV 用户。")
            Text("如果当前服务实际只开放 HTTP，请不要只把地址文字改成 HTTPS。HTTPS 需要服务器或反向代理先配置 TLS 证书。")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

          Spacer(minLength: 24)
        }
        .padding(.horizontal, 22)
      }
      .background(Color(uiColor: .systemBackground).ignoresSafeArea())
      .navigationBarHidden(true)
      .onAppear { loadStoredConfiguration() }
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

  @ViewBuilder
  private func setupField<Content: View>(
    title: String,
    icon: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(CinevaTheme.accent)
        .frame(width: 32, height: 32)
        .background(CinevaTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        content()
          .font(.body)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 64)
    .background(
      Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
  }

  private func loadStoredConfiguration() {
    guard let configuration = WebDAVCredentialStore.shared.configuration else { return }
    serverURL = configuration.serverURL
    username = configuration.username
    password = configuration.password
    rootPath = configuration.normalizedRootPath
  }

  private func connect() {
    guard !isConnecting else { return }
    let configuration = WebDAVMountConfiguration(
      serverURL: serverURL,
      username: username,
      password: password,
      rootPath: rootPath
    )
    guard configuration.normalizedWebDAVURL != nil else {
      errorMessage = "请输入正确的 OpenList / AList 地址。"
      return
    }

    isConnecting = true
    errorMessage = nil
    Task {
      do {
        try await appState.api.validate(configuration: configuration)
        WebDAVCredentialStore.shared.save(configuration)
        await appState.api.clearMountCache()
        await MainActor.run {
          appState.finishConfiguration(rootFolderID: configuration.normalizedRootPath)
          appState.markMediaConnected()
          isConnecting = false
          dismiss()
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          isConnecting = false
        }
      }
    }
  }
}
