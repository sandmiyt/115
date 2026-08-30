import SwiftUI

struct SetupView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState

  @State private var serverURL = ""
  @State private var username = ""
  @State private var password = ""
  @State private var rootPath = "/115"
  @State private var selectedSource: MediaSourceKind = .cloud115
  @State private var isConnecting = false
  @State private var errorMessage: String?
  @State private var authorizationCoordinator: Cloud115AuthorizationCoordinator?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          Spacer(minLength: 12)

          VStack(spacing: 13) {
            CinevaLogoMark(size: 88)
            VStack(spacing: 5) {
              Text("添加媒体源")
                .font(.system(size: 34, weight: .bold, design: .rounded))
              Text("每位用户都可以连接自己的网盘")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }

          sourcePicker

          Group {
            switch selectedSource {
            case .cloud115: cloud115Setup
            case .webDAV: webDAVSetup
            }
          }
          .transition(.opacity.combined(with: .scale(scale: 0.98)))

          Spacer(minLength: 22)
        }
        .padding(.horizontal, 22)
      }
      .background(Color(uiColor: .systemBackground).ignoresSafeArea())
      .navigationTitle("连接网盘")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("完成") { dismiss() }
        }
      }
      .onAppear {
        loadStoredConfiguration()
        selectedSource = appState.isConfigured ? appState.mediaSourceKind : .cloud115
      }
      .onDisappear {
        authorizationCoordinator?.cancel()
      }
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

  private var sourcePicker: some View {
    Picker("媒体源", selection: $selectedSource) {
      Label("115 网盘", systemImage: "externaldrive.badge.icloud")
        .tag(MediaSourceKind.cloud115)
      Label("OpenList", systemImage: "server.rack")
        .tag(MediaSourceKind.webDAV)
    }
    .pickerStyle(.segmented)
    .disabled(isConnecting)
    .animation(.easeOut(duration: 0.22), value: selectedSource)
  }

  private var cloud115Setup: some View {
    VStack(spacing: 16) {
      VStack(spacing: 13) {
        Image(systemName: "externaldrive.badge.icloud")
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(CinevaTheme.brandGradient)
          .frame(width: 66, height: 66)
          .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
          )

        VStack(spacing: 6) {
          Text("直接连接 115 网盘")
            .font(.title3.weight(.semibold))
          Text("使用 115 官方授权登录，无需填写密码，也不依赖 OpenList 中转。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.top, 8)

      Button(action: connectCloud115) {
        HStack(spacing: 9) {
          if isConnecting {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "person.crop.circle.badge.checkmark")
            Text("授权连接 115 网盘").fontWeight(.semibold)
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
      .disabled(isConnecting)

      VStack(spacing: 5) {
        Label("登录在 iOS 系统安全授权页中完成", systemImage: "checkmark.shield.fill")
        Text("Cineva 不会读取或保存你的 115 密码；授权令牌保存在本机钥匙串。")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .padding(18)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 24, style: .continuous)
    )
  }

  private var webDAVSetup: some View {
    VStack(spacing: 14) {
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

      Button(action: connectWebDAV) {
        HStack(spacing: 9) {
          if isConnecting {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "externaldrive.connected.to.line.below.fill")
            Text("连接 OpenList / AList").fontWeight(.semibold)
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

      VStack(spacing: 5) {
        Label("服务器地址会自动补齐 /dav/", systemImage: "checkmark.shield.fill")
        Text("建议为每位用户建立独立、只读的 WebDAV 身份，不要共享管理员账号。")
        Text("HTTPS 必须由服务器或反向代理真正配置 TLS；不能只把 http 文本改成 https。")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
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

  private func connectWebDAV() {
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
          appState.finishConfiguration(source: .webDAV, rootFolderID: configuration.normalizedRootPath)
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

  private func connectCloud115() {
    guard !isConnecting else { return }
    isConnecting = true
    errorMessage = nil
    let coordinator = Cloud115AuthorizationCoordinator()
    authorizationCoordinator = coordinator

    Task {
      do {
        try await coordinator.authorize()
        try await appState.api.validateCloud115Credentials()
        await MainActor.run {
          appState.finishConfiguration(source: .cloud115, rootFolderID: "0")
          appState.markMediaConnected()
          authorizationCoordinator = nil
          isConnecting = false
          dismiss()
        }
      } catch {
        await MainActor.run {
          authorizationCoordinator = nil
          errorMessage = error.localizedDescription
          isConnecting = false
        }
      }
    }
  }
}
