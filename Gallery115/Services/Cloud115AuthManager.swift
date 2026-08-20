import Foundation

actor Cloud115AuthManager {
  static let shared = Cloud115AuthManager()

  private let store = Cloud115SessionStore.shared
  private let session: URLSession
  private let authURL = URL(string: "https://passportapi.115.com")!
  private var refreshTask: Task<Cloud115Session, Error>?

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    session = URLSession(configuration: config)
  }

  func accessToken() async throws -> String {
    if let current = store.session, !current.accessToken.isEmpty {
      return current.accessToken
    }
    return try await refreshSession().accessToken
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

  func clearSession() {
    store.clear()
  }

  private static func performRefresh(
    refreshToken: String,
    session: URLSession,
    authURL: URL
  ) async throws -> Cloud115Session {
    var lastTransientError: Error?

    // Primary path: 115 official Open API refresh endpoint.
    for attempt in 0..<2 {
      do {
        let url = authURL.appending(path: "/open/refreshToken")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Cloud115Provider.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = ["refresh_token": refreshToken].cloud115FormEncoded.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw CloudProviderError.network("115 登录状态续期时没有收到有效网络响应。")
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
        if case .authenticationRequired = error {
          throw error
        }
        lastTransientError = error
      } catch {
        lastTransientError = CloudProviderError.network(error.localizedDescription)
      }

      if attempt == 0 {
        try? await Task.sleep(for: .milliseconds(500))
      }
    }

    // Compatibility bridge for users who were authorized through the legacy login broker.
    // It is deliberately isolated here; no library/player code depends on it.
    for endpoint in [
      "https://api.oplist.org/115cloud/renewapi",
      "https://api-cn.oplist.org/115cloud/renewapi",
    ] {
      do {
        guard var components = URLComponents(string: endpoint) else { continue }
        components.queryItems = [URLQueryItem(name: "refresh_ui", value: refreshToken)]
        guard let url = components.url else { continue }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Cloud115Provider.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { continue }
        if (200..<300).contains(http.statusCode) {
          return try parseRefreshResponse(
            data: data,
            httpStatus: http.statusCode,
            fallbackRefreshToken: refreshToken
          )
        }
      } catch let error as CloudProviderError {
        if case .authenticationRequired = error {
          throw error
        }
        lastTransientError = error
      } catch {
        lastTransientError = CloudProviderError.network(error.localizedDescription)
      }
    }

    throw lastTransientError
      ?? CloudProviderError.network("115 登录状态续期失败，请检查网络后重试。")
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

    if !accessToken.isEmpty {
      return Cloud115Session(
        accessToken: accessToken,
        refreshToken: returnedRefreshToken.isEmpty ? fallbackRefreshToken : returnedRefreshToken
      )
    }

    let code = cloud115Int64(object["code"])
    let message = [
      cloud115String(object["message"]),
      cloud115String(object["error"]),
      cloud115String(object["error_description"]),
      cloud115String(object["text"]),
    ].first(where: { !$0.isEmpty }) ?? "115 登录状态续期失败。"

    if httpStatus == 401 || httpStatus == 403 || isPermanentAuthFailure(code: code, message: message) {
      throw CloudProviderError.authenticationRequired(
        "115 登录授权已失效，请重新连接 115 网盘。"
      )
    }
    if httpStatus == 429 || message.localizedCaseInsensitiveContains("too many") {
      throw CloudProviderError.rateLimited("115 登录服务请求过于频繁，Cineva 稍后会再次尝试。")
    }
    throw CloudProviderError.remote(code: code, message: message)
  }

  private static func isPermanentAuthFailure(code: Int64, message: String) -> Bool {
    let text = message.lowercased()
    return code == 40140116
      || text.contains("no auth")
      || text.contains("refresh token") && (text.contains("invalid") || text.contains("expired"))
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
