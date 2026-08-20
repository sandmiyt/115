import SwiftUI
import WebKit

struct SetupView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState

  @State private var selectedSource: MediaSourceKind = .cloud115
  @State private var authorizationSession: Cloud115AuthorizationSession?
  @State private var serverURL = ""
  @State private var username = ""
  @State private var password = ""
  @State private var rootPath = "/115"
  @State private var isConnecting = false
  @State private var errorMessage: String?

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

          cloud115Setup

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
        selectedSource = .cloud115
      }
      .sheet(item: $authorizationSession) { session in
        Cloud115AuthorizationSheet(session: session) { result in
          authorizationSession = nil
          handleAuthorizationResult(result)
        }
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

  private var cloud115Setup: some View {
    VStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        Label("用户本人授权", systemImage: "person.badge.key.fill")
          .font(.headline)
        Text("点击后进入 115 授权页面。每个用户只需要登录自己的 115 账号，Cineva 会自动维护登录状态，不需要配置服务器、OpenList、WebDAV、IP 或端口。")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Divider()

        HStack(spacing: 9) {
          Image(systemName: "lock.shield.fill")
            .foregroundStyle(.green)
          Text("授权凭据保存在本机 Keychain；Access Token 到期前自动续期，普通网络故障不会清除登录。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .background(
        Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      )

      Button(action: begin115Authorization) {
        HStack(spacing: 9) {
          if isConnecting {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "externaldrive.badge.icloud")
            Text(CredentialStore.shared.hasRefreshToken ? "重新授权 115 网盘" : "授权我的 115 网盘")
              .fontWeight(.semibold)
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

      Text("每位用户使用自己的 115 授权。Cineva 不共享网盘账号，也不会要求普通用户维护 OpenList。")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
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

  private func begin115Authorization() {
    guard !isConnecting else { return }
    isConnecting = true
    errorMessage = nil

    Task {
      do {
        let session = try await Cloud115AuthorizationClient.makeSession()
        await MainActor.run {
          authorizationSession = session
          isConnecting = false
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          isConnecting = false
        }
      }
    }
  }

  private func handleAuthorizationResult(_ result: Result<Cloud115Credentials, Error>) {
    switch result {
    case .failure(let error):
      if !(error is CancellationError) {
        errorMessage = error.localizedDescription
      }
    case .success(let credentials):
      isConnecting = true
      Cloud115SessionStore.shared.save(
        accessToken: credentials.accessToken,
        refreshToken: credentials.refreshToken,
        expiresIn: credentials.expiresIn
      )

      Task {
        do {
          try await Cloud115Provider.shared.validateCredentials()
          await MainActor.run {
            appState.finishConfiguration(source: .cloud115, rootFolderID: "0")
            appState.markMediaConnected()
            isConnecting = false
            dismiss()
          }
        } catch let error as CloudProviderError {
          if case .authenticationRequired = error {
            CredentialStore.shared.clear()
            await MainActor.run {
              errorMessage = error.localizedDescription
              isConnecting = false
            }
          } else {
            // OAuth already returned a valid token pair. Keep it on a temporary
            // availability/rate-limit failure instead of forcing another login.
            await MainActor.run {
              appState.finishConfiguration(source: .cloud115, rootFolderID: "0")
              appState.markMediaUsingCache()
              isConnecting = false
              dismiss()
            }
          }
        } catch {
          await MainActor.run {
            appState.finishConfiguration(source: .cloud115, rootFolderID: "0")
            appState.markMediaUsingCache()
            isConnecting = false
            dismiss()
          }
        }
      }
    }
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
}

struct Cloud115Credentials: Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresIn: TimeInterval?
}

struct Cloud115AuthorizationSession: Identifiable, @unchecked Sendable {
  let id = UUID()
  let loginURL: URL
  let cookies: [HTTPCookie]
  let callbackHosts: Set<String>
}

enum Cloud115AuthorizationError: LocalizedError {
  case invalidResponse
  case authorizationURLMissing
  case callbackMalformed
  case remote(String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "115 授权服务返回了无法识别的响应。"
    case .authorizationURLMissing:
      return "没有取得 115 登录地址，请稍后重试。"
    case .callbackMalformed:
      return "115 授权完成，但返回的登录信息无法读取。"
    case .remote(let message):
      return message.isEmpty ? "115 授权失败。" : message
    }
  }
}

enum Cloud115AuthorizationClient {
  static func makeSession() async throws -> Cloud115AuthorizationSession {
    let endpoints = authorizationEndpoints()
    var lastError: Error?

    for endpoint in endpoints {
      do {
        guard var components = URLComponents(string: endpoint) else {
          throw Cloud115AuthorizationError.invalidResponse
        }
        components.queryItems = [
          URLQueryItem(name: "driver_txt", value: "115cloud_go"),
          URLQueryItem(name: "server_use", value: "true"),
        ]
        guard let url = components.url else {
          throw Cloud115AuthorizationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(APIClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
          throw Cloud115AuthorizationError.invalidResponse
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw Cloud115AuthorizationError.invalidResponse
        }
        let loginURLText = cloud115String(object["text"])
        guard let loginURL = URL(string: loginURLText), loginURL.scheme == "https" else {
          let message = [
            cloud115String(object["message"]),
            cloud115String(object["error"]),
          ].first(where: { !$0.isEmpty })
          if let message {
            throw Cloud115AuthorizationError.remote(message)
          }
          throw Cloud115AuthorizationError.authorizationURLMissing
        }

        let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
          if let key = pair.key as? String {
            result[key] = String(describing: pair.value)
          }
        }
        var cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        if let storedCookies = HTTPCookieStorage.shared.cookies(for: url) {
          for cookie in storedCookies where !cookies.contains(where: { $0.name == cookie.name }) {
            cookies.append(cookie)
          }
        }

        var callbackHosts = Set<String>()
        if let host = url.host?.lowercased() { callbackHosts.insert(host) }
        return Cloud115AuthorizationSession(
          loginURL: loginURL,
          cookies: cookies,
          callbackHosts: callbackHosts
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? Cloud115AuthorizationError.invalidResponse
  }

  private static func authorizationEndpoints() -> [String] {
    var results: [String] = []

    if let configured = Bundle.main.object(forInfoDictionaryKey: "Cineva115AuthorizationURL") as? String {
      let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        if trimmed.lowercased().contains("/115cloud/requests") {
          results.append(trimmed)
        } else {
          results.append(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/115cloud/requests")
        }
      }
    }

    results.append(contentsOf: [
      "https://api.oplist.org/115cloud/requests",
      "https://api-cn.oplist.org/115cloud/requests",
    ])
    var seen = Set<String>()
    return results.filter { seen.insert($0).inserted }
  }
}

struct Cloud115AuthorizationSheet: View {
  @Environment(\.dismiss) private var dismiss
  let session: Cloud115AuthorizationSession
  let completion: (Result<Cloud115Credentials, Error>) -> Void

  var body: some View {
    NavigationStack {
      Cloud115AuthorizationWebView(session: session) { result in
        completion(result)
        dismiss()
      }
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle("登录 115")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("取消") {
            completion(.failure(CancellationError()))
            dismiss()
          }
        }
      }
    }
  }
}

private struct Cloud115AuthorizationWebView: UIViewRepresentable {
  let session: Cloud115AuthorizationSession
  let completion: (Result<Cloud115Credentials, Error>) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(callbackHosts: session.callbackHosts, completion: completion)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true

    let cookieStore = configuration.websiteDataStore.httpCookieStore
    let group = DispatchGroup()
    for cookie in session.cookies {
      group.enter()
      cookieStore.setCookie(cookie) { group.leave() }
    }
    group.notify(queue: .main) {
      webView.load(URLRequest(url: session.loginURL))
    }
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let callbackHosts: Set<String>
    private let completion: (Result<Cloud115Credentials, Error>) -> Void
    private var didFinish = false

    init(
      callbackHosts: Set<String>,
      completion: @escaping (Result<Cloud115Credentials, Error>) -> Void
    ) {
      self.callbackHosts = callbackHosts
      self.completion = completion
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      if let url = navigationAction.request.url, consumeCallbackIfPresent(url) {
        decisionHandler(.cancel)
      } else {
        decisionHandler(.allow)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      if let url = webView.url {
        _ = consumeCallbackIfPresent(url)
      }
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
    }

    private func consumeCallbackIfPresent(_ url: URL) -> Bool {
      guard !didFinish,
        let host = url.host?.lowercased(),
        callbackHosts.contains(host),
        let fragment = url.fragment,
        !fragment.isEmpty
      else {
        return false
      }

      didFinish = true
      do {
        let credentials = try Self.decodeCredentials(fragment)
        completion(.success(credentials))
      } catch {
        completion(.failure(error))
      }
      return true
    }

    private static func decodeCredentials(_ fragment: String) throws -> Cloud115Credentials {
      var encoded = fragment.removingPercentEncoding ?? fragment
      encoded = encoded.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      let remainder = encoded.count % 4
      if remainder != 0 {
        encoded += String(repeating: "=", count: 4 - remainder)
      }

      guard let data = Data(base64Encoded: encoded),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        throw Cloud115AuthorizationError.callbackMalformed
      }

      if let message = object["message_err"] as? String, !message.isEmpty {
        throw Cloud115AuthorizationError.remote(message)
      }
      guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
        let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty
      else {
        throw Cloud115AuthorizationError.callbackMalformed
      }
      let expiresIn = cloud115NumericDouble(object["expires_in"])
      return Cloud115Credentials(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn > 0 ? expiresIn : 2 * 60 * 60
      )
    }
  }
}
