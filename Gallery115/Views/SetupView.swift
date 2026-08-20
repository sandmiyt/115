import SwiftUI
import WebKit

struct SetupView: View {
  @Environment(AppState.self) private var appState
  @State private var authorizationSession: Cloud115AuthorizationSession?
  @State private var isConnecting = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Spacer(minLength: 34)

        VStack(spacing: 17) {
          CinevaLogoMark(size: 104)

          VStack(spacing: 7) {
            Text("Cineva")
              .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("连接 115，开始你的私人影院")
              .font(.headline)
              .foregroundStyle(.secondary)
          }

          Text("无需手动复制 Token。授权成功后，Cineva 会自动取得访问凭据并安全保存到本机 Keychain。")
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
        }

        Spacer(minLength: 30)

        Button(action: beginAuthorization) {
          HStack(spacing: 10) {
            if isConnecting {
              ProgressView().tint(.white)
            } else {
              Image(systemName: "externaldrive.badge.icloud")
              Text("连接 115 网盘")
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

        HStack(spacing: 7) {
          Image(systemName: "lock.shield.fill")
          Text("仅在需要时打开 115 授权页 · Token 不会显示在界面中")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 13)

        Spacer(minLength: 30)
      }
      .padding(.horizontal, 24)
      .background(Color(uiColor: .systemBackground).ignoresSafeArea())
      .navigationBarHidden(true)
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

  private func beginAuthorization() {
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
      CredentialStore.shared.save(
        accessToken: credentials.accessToken,
        refreshToken: credentials.refreshToken
      )

      Task {
        do {
          try await appState.api.validateCredentials()
          await MainActor.run {
            appState.finishConfiguration(rootFolderID: "0")
            isConnecting = false
          }
        } catch {
          CredentialStore.shared.clear()
          await MainActor.run {
            errorMessage = error.localizedDescription
            isConnecting = false
          }
        }
      }
    }
  }
}

struct Cloud115Credentials: Sendable {
  let accessToken: String
  let refreshToken: String
}

struct Cloud115AuthorizationSession: Identifiable, @unchecked Sendable {
  let id = UUID()
  let loginURL: URL
  let cookies: [HTTPCookie]
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
    let endpoints = [
      "https://api.oplist.org/115cloud/requests",
      "https://api-cn.oplist.org/115cloud/requests",
    ]

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
        request.setValue("Cineva-iOS/1.7", forHTTPHeaderField: "User-Agent")

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
        return Cloud115AuthorizationSession(loginURL: loginURL, cookies: cookies)
      } catch {
        lastError = error
      }
    }

    throw lastError ?? Cloud115AuthorizationError.invalidResponse
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
    Coordinator(completion: completion)
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
      cookieStore.setCookie(cookie) {
        group.leave()
      }
    }
    group.notify(queue: .main) {
      webView.load(URLRequest(url: session.loginURL))
    }
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let completion: (Result<Cloud115Credentials, Error>) -> Void
    private var didFinish = false

    init(completion: @escaping (Result<Cloud115Credentials, Error>) -> Void) {
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
        host == "api.oplist.org" || host == "api-cn.oplist.org",
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
      return Cloud115Credentials(accessToken: accessToken, refreshToken: refreshToken)
    }
  }
}
