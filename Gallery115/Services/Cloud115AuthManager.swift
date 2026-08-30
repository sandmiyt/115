import AuthenticationServices
import Foundation
import UIKit

actor Cloud115AuthManager {
  static let shared = Cloud115AuthManager()

  private let store = Cloud115SessionStore.shared
  private let session: URLSession
  private let authURL = URL(string: "https://qrcodeapi.115.com")!
  private var refreshTask: Task<Cloud115Session, Error>?

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    session = URLSession(configuration: config)
  }

  func accessToken() async throws -> String {
    guard let current = store.session else {
      throw CloudProviderError.authenticationRequired("尚未连接 115 网盘，请先登录。")
    }

    if !current.needsAccessTokenRefresh() {
      return current.accessToken
    }

    do {
      return try await refreshSession().accessToken
    } catch let error as CloudProviderError {
      // 115 rejects refreshes that happen too frequently (40140117). When a valid
      // access token still exists, keep using it instead of turning a harmless
      // timing race into a user-visible logout.
      if case .rateLimited = error, !current.accessToken.isEmpty {
        return current.accessToken
      }
      throw error
    }
  }

  @discardableResult
  func refreshSession() async throws -> Cloud115Session {
    if let refreshTask {
      return try await refreshTask.value
    }

    guard let current = store.session, !current.refreshToken.isEmpty else {
      throw CloudProviderError.authenticationRequired("尚未连接 115 网盘，请先登录。")
    }

    let refreshToken = current.refreshToken
    let session = self.session
    let authURL = self.authURL
    let store = self.store
    let task = Task<Cloud115Session, Error> {
      let refreshed = try await Self.performRefresh(
        refreshToken: refreshToken,
        session: session,
        authURL: authURL
      )
      // 115 refresh tokens rotate. Save the entire pair inside the single-flight task
      // so every waiter observes the new session before the task completes.
      store.save(refreshed)
      return refreshed
    }
    refreshTask = task
    defer { refreshTask = nil }

    return try await task.value
  }

  func replaceSession(accessToken: String, refreshToken: String) {
    store.save(accessToken: accessToken, refreshToken: refreshToken)
  }

  func replaceSession(_ session: Cloud115Session) {
    store.save(session)
  }

  func clearSession() {
    store.clear()
  }

  private static func performRefresh(
    refreshToken: String,
    session: URLSession,
    authURL: URL
  ) async throws -> Cloud115Session {
    let brokerURL = configuredRefreshBrokerURL()
    let url = brokerURL ?? authURL.appending(path: "/open/refreshToken")
    let maxAttempts = brokerURL == nil ? 1 : 2
    var lastNetworkError: Error?

    for attempt in 0..<maxAttempts {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = 20
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue(Cloud115Provider.userAgent, forHTTPHeaderField: "User-Agent")
      request.httpBody = ["refresh_token": refreshToken].cloud115FormEncoded.data(using: .utf8)

      do {
        // A 115 refresh token is one-time-use. Cineva's own broker makes this
        // operation idempotent, so a lost mobile response can safely be retried.
        // Direct-to-115 fallback is deliberately attempted only once.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw CloudProviderError.network("115 登录状态续期时没有收到有效网络响应。")
        }
        if http.statusCode == 429 {
          throw CloudProviderError.rateLimited("115 登录状态刷新过于频繁，Cineva 会继续使用当前登录状态。")
        }
        if http.statusCode >= 500 {
          throw CloudProviderError.network("115 登录服务暂时不可用。")
        }
        return try parseRefreshResponse(
          data: data,
          httpStatus: http.statusCode,
          fallbackRefreshToken: refreshToken
        )
      } catch let error as CloudProviderError {
        if case .network = error, brokerURL != nil, attempt + 1 < maxAttempts {
          lastNetworkError = error
          try? await Task.sleep(for: .milliseconds(350))
          continue
        }
        throw error
      } catch {
        lastNetworkError = error
        if brokerURL != nil, attempt + 1 < maxAttempts {
          try? await Task.sleep(for: .milliseconds(350))
          continue
        }
      }
    }

    _ = lastNetworkError
    throw CloudProviderError.network(
      "115 登录状态续期遇到网络中断。Cineva 已保留原凭据，不会自动清除授权。"
    )
  }

  private static func configuredRefreshBrokerURL() -> URL? {
    guard let configured = Bundle.main.object(forInfoDictionaryKey: "Cineva115AuthorizationURL") as? String else {
      return nil
    }
    let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
    let path = components.path
    if path.hasSuffix("/115cloud/requests") {
      components.path = String(path.dropLast("/115cloud/requests".count)) + "/115cloud/refresh"
    } else if path.hasSuffix("/requests") {
      components.path = String(path.dropLast("/requests".count)) + "/refresh"
    } else {
      components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/115cloud/refresh"
      if !components.path.hasPrefix("/") { components.path = "/" + components.path }
    }
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private static func parseRefreshResponse(
    data: Data,
    httpStatus: Int,
    fallbackRefreshToken: String
  ) throws -> Cloud115Session {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      if httpStatus == 401 || httpStatus == 403 {
        throw CloudProviderError.authenticationRequired("115 登录授权已失效，请重新连接 115 网盘。")
      }
      throw CloudProviderError.invalidResponse("登录状态续期")
    }

    let payload = (object["data"] as? [String: Any]) ?? object
    let accessToken = cloud115String(payload["access_token"])
    let returnedRefreshToken = cloud115String(payload["refresh_token"])
    let expiresIn = cloud115NumericDouble(payload["expires_in"])

    if !accessToken.isEmpty {
      return Cloud115Session(
        accessToken: accessToken,
        refreshToken: returnedRefreshToken.isEmpty ? fallbackRefreshToken : returnedRefreshToken,
        expiresIn: expiresIn > 0 ? expiresIn : 2 * 60 * 60
      )
    }

    let code = {
      let direct = cloud115Int64(object["code"])
      return direct != 0 ? direct : cloud115Int64(object["errno"])
    }()
    let message = [
      cloud115String(object["message"]),
      cloud115String(object["error"]),
      cloud115String(object["error_description"]),
      cloud115String(object["text"]),
    ].first(where: { !$0.isEmpty }) ?? "115 登录状态续期失败。"

    if code == 40140117 || httpStatus == 429 || message.localizedCaseInsensitiveContains("too many") {
      throw CloudProviderError.rateLimited("115 登录状态刷新过于频繁，Cineva 会继续使用当前登录状态。")
    }
    if httpStatus == 401 || httpStatus == 403 || isPermanentAuthFailure(code: code, message: message) {
      throw CloudProviderError.authenticationRequired(
        "115 登录授权已失效，请重新连接 115 网盘。"
      )
    }
    throw CloudProviderError.remote(code: code, message: message)
  }

  private static func isPermanentAuthFailure(code: Int64, message: String) -> Bool {
    let text = message.lowercased()
    return [40140114, 40140115, 40140116, 40140119, 40140120].contains(code)
      || text.contains("no auth")
      || text.contains("refresh token") && (text.contains("invalid") || text.contains("expired"))
  }
}

enum Cloud115AuthorizationError: LocalizedError {
  case notConfigured
  case invalidBrokerResponse
  case unableToStart
  case cancelled
  case invalidCallback
  case expiredTicket

  var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "尚未配置 115 授权服务地址，请在 Info.plist 的 Cineva115AuthorizationURL 中填写已部署的 HTTPS 地址。"
    case .invalidBrokerResponse:
      return "115 授权服务返回了无法识别的响应。"
    case .unableToStart:
      return "无法打开 115 授权页面，请稍后重试。"
    case .cancelled:
      return "已取消 115 网盘授权。"
    case .invalidCallback:
      return "没有收到有效的 115 授权回调。"
    case .expiredTicket:
      return "115 授权结果已过期或已经使用，请重新授权。"
    }
  }
}

/// Owns the system authentication sheet. The app receives only a short-lived,
/// one-time ticket; access and refresh tokens are fetched over HTTPS and then
/// stored atomically in Keychain by Cloud115AuthManager.
@MainActor
final class Cloud115AuthorizationCoordinator: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  private var authenticationSession: ASWebAuthenticationSession?
  private let networkSession: URLSession

  override init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    networkSession = URLSession(configuration: configuration)
    super.init()
  }

  func authorize() async throws {
    let requestEndpoint = try Self.configuredRequestEndpoint()
    let authorizationURL = try await fetchAuthorizationURL(from: requestEndpoint)
    let callbackURL = try await beginSystemAuthorization(at: authorizationURL)
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "cineva115",
      let ticket = components.queryItems?.first(where: { $0.name == "ticket" })?.value,
      !ticket.isEmpty
    else {
      throw Cloud115AuthorizationError.invalidCallback
    }

    let exchangeEndpoint = try Self.sessionEndpoint(from: requestEndpoint)
    let session = try await exchange(ticket: ticket, at: exchangeEndpoint)
    await Cloud115AuthManager.shared.replaceSession(session)
  }

  func cancel() {
    authenticationSession?.cancel()
    authenticationSession = nil
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
      return keyWindow
    }
    if let window = scenes.flatMap(\.windows).first { return window }
    return UIWindow(frame: UIScreen.main.bounds)
  }

  private func fetchAuthorizationURL(from endpoint: URL) async throws -> URL {
    var request = URLRequest(url: endpoint)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue(Cloud115Provider.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await networkSession.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      cloud115BoolValue(object["state"]),
      let url = URL(string: cloud115String(object["text"])),
      url.scheme?.lowercased() == "https"
    else {
      throw Cloud115AuthorizationError.invalidBrokerResponse
    }
    return url
  }

  private func beginSystemAuthorization(at url: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: "cineva115"
      ) { [weak self] callbackURL, error in
        Task { @MainActor in
          self?.authenticationSession = nil
          if let authenticationError = error as? ASWebAuthenticationSessionError,
            authenticationError.code == .canceledLogin
          {
            continuation.resume(throwing: Cloud115AuthorizationError.cancelled)
          } else if let error {
            continuation.resume(throwing: error)
          } else if let callbackURL {
            continuation.resume(returning: callbackURL)
          } else {
            continuation.resume(throwing: Cloud115AuthorizationError.invalidCallback)
          }
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      authenticationSession = session
      guard session.start() else {
        authenticationSession = nil
        continuation.resume(throwing: Cloud115AuthorizationError.unableToStart)
        return
      }
    }
  }

  private func exchange(ticket: String, at endpoint: URL) async throws -> Cloud115Session {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(Cloud115Provider.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = ["ticket": ticket].cloud115FormEncoded.data(using: .utf8)
    let (data, response) = try await networkSession.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw Cloud115AuthorizationError.invalidBrokerResponse
    }
    guard (200...299).contains(http.statusCode) else {
      if http.statusCode == 401 { throw Cloud115AuthorizationError.expiredTicket }
      throw Cloud115AuthorizationError.invalidBrokerResponse
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Cloud115AuthorizationError.invalidBrokerResponse
    }
    let payload = (object["data"] as? [String: Any]) ?? object
    let accessToken = cloud115String(payload["access_token"])
    let refreshToken = cloud115String(payload["refresh_token"])
    guard !accessToken.isEmpty, !refreshToken.isEmpty else {
      throw Cloud115AuthorizationError.invalidBrokerResponse
    }
    let expiresIn = cloud115NumericDouble(payload["expires_in"])
    return Cloud115Session(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn > 0 ? expiresIn : 2 * 60 * 60
    )
  }

  private static func configuredRequestEndpoint() throws -> URL {
    guard let configured = Bundle.main.object(
      forInfoDictionaryKey: "Cineva115AuthorizationURL"
    ) as? String else { throw Cloud115AuthorizationError.notConfigured }
    let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https", components.host != nil
    else { throw Cloud115AuthorizationError.notConfigured }
    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !path.hasSuffix("115cloud/requests") {
      components.path = "/" + ([path, "115cloud/requests"].filter { !$0.isEmpty }.joined(separator: "/"))
    }
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw Cloud115AuthorizationError.notConfigured }
    return url
  }

  private static func sessionEndpoint(from requestEndpoint: URL) throws -> URL {
    guard var components = URLComponents(url: requestEndpoint, resolvingAgainstBaseURL: false)
    else { throw Cloud115AuthorizationError.notConfigured }
    if components.path.hasSuffix("/115cloud/requests") {
      components.path = String(components.path.dropLast("/requests".count)) + "/session"
    } else {
      components.path = components.path.replacingOccurrences(of: "/requests", with: "/session")
    }
    guard let url = components.url else { throw Cloud115AuthorizationError.notConfigured }
    return url
  }
}

private func cloud115BoolValue(_ value: Any?) -> Bool {
  switch value {
  case let value as Bool: return value
  case let value as NSNumber: return value.boolValue
  case let value as String: return ["1", "true", "yes"].contains(value.lowercased())
  default: return false
  }
}

func cloud115String(_ value: Any?) -> String {
  switch value {
  case let value as String:
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  case let value as NSNumber:
    return value.stringValue
  default:
    return ""
  }
}


func cloud115NumericDouble(_ value: Any?) -> Double {
  switch value {
  case let value as NSNumber: return value.doubleValue
  case let value as String: return Double(value) ?? 0
  default: return 0
  }
}

func cloud115Int64(_ value: Any?) -> Int64 {
  switch value {
  case let value as NSNumber: return value.int64Value
  case let value as String: return Int64(value) ?? 0
  default: return 0
  }
}

extension Dictionary where Key == String, Value == String {
  var cloud115FormEncoded: String {
    map { key, value in
      "\(key.cloud115URLFormEncoded)=\(value.cloud115URLFormEncoded)"
    }
    .sorted()
    .joined(separator: "&")
  }
}

extension String {
  var cloud115URLFormEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .cloud115URLQueryValueAllowed) ?? self
  }
}

extension CharacterSet {
  static let cloud115URLQueryValueAllowed: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()
}
