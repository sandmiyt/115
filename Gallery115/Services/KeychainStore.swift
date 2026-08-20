import Foundation
import Security

struct Cloud115Session: Codable, Equatable, Sendable {
  let accessToken: String
  let refreshToken: String
  let accessTokenExpiresAt: Date?
  let updatedAt: Date

  init(
    accessToken: String,
    refreshToken: String,
    expiresIn: TimeInterval? = nil,
    accessTokenExpiresAt: Date? = nil,
    updatedAt: Date = Date()
  ) {
    self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if let accessTokenExpiresAt {
      self.accessTokenExpiresAt = accessTokenExpiresAt
    } else if let expiresIn, expiresIn > 0 {
      self.accessTokenExpiresAt = updatedAt.addingTimeInterval(expiresIn)
    } else {
      self.accessTokenExpiresAt = nil
    }
    self.updatedAt = updatedAt
  }

  /// 115 Open access tokens are currently refreshed on roughly a two-hour cadence.
  /// Prefer the server-provided expires_in value; old sessions without it use a
  /// conservative fallback so Cineva refreshes before playback hits a 401.
  func needsAccessTokenRefresh(now: Date = Date()) -> Bool {
    guard !accessToken.isEmpty else { return true }
    if let accessTokenExpiresAt {
      return now >= accessTokenExpiresAt.addingTimeInterval(-5 * 60)
    }
    return now.timeIntervalSince(updatedAt) >= 105 * 60
  }
}

/// Stores the complete 115 OAuth session as one Keychain value.
/// A rotating refresh token is therefore never persisted separately from its matching access token.
final class Cloud115SessionStore: @unchecked Sendable {
  static let shared = Cloud115SessionStore()

  private let service = "com.xiaocai.gallery115.credentials"
  private let sessionAccount = "oauth-session-v2"
  private let legacyAccessAccount = "access-token"
  private let legacyRefreshAccount = "refresh-token"
  private let lock = NSLock()

  private init() {}

  var session: Cloud115Session? {
    lock.lock()
    defer { lock.unlock() }
    return readSessionLocked() ?? migrateLegacySessionLocked()
  }

  var hasRefreshToken: Bool {
    guard let token = session?.refreshToken else { return false }
    return !token.isEmpty
  }

  func save(accessToken: String, refreshToken: String, expiresIn: TimeInterval? = nil) {
    save(
      Cloud115Session(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn
      )
    )
  }

  func save(_ session: Cloud115Session) {
    guard !session.refreshToken.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    writeSessionLocked(session)
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    delete(account: sessionAccount)
    delete(account: legacyAccessAccount)
    delete(account: legacyRefreshAccount)
  }

  private func readSessionLocked() -> Cloud115Session? {
    guard let data = readData(account: sessionAccount) else { return nil }
    return try? JSONDecoder().decode(Cloud115Session.self, from: data)
  }

  @discardableResult
  private func migrateLegacySessionLocked() -> Cloud115Session? {
    guard let refreshData = readData(account: legacyRefreshAccount),
      let refresh = String(data: refreshData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !refresh.isEmpty
    else {
      return nil
    }

    let access = readData(account: legacyAccessAccount)
      .flatMap { String(data: $0, encoding: .utf8) }?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let migrated = Cloud115Session(accessToken: access, refreshToken: refresh)
    writeSessionLocked(migrated)
    delete(account: legacyAccessAccount)
    delete(account: legacyRefreshAccount)
    return migrated
  }

  private func writeSessionLocked(_ session: Cloud115Session) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    writeData(data, account: sessionAccount)
  }

  private func readData(account: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  private func writeData(_ data: Data, account: String) {
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)

    if status == errSecItemNotFound {
      var add = baseQuery
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }

  private func delete(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

/// Compatibility facade for existing views while the app is migrated to Cloud115Provider.
final class CredentialStore: @unchecked Sendable {
  static let shared = CredentialStore()
  private let store = Cloud115SessionStore.shared

  private init() {}

  var accessToken: String? {
    get {
      let value = store.session?.accessToken ?? ""
      return value.isEmpty ? nil : value
    }
    set {
      guard let refresh = store.session?.refreshToken, !refresh.isEmpty else { return }
      store.save(accessToken: newValue ?? "", refreshToken: refresh)
    }
  }

  var refreshToken: String? {
    get {
      let value = store.session?.refreshToken ?? ""
      return value.isEmpty ? nil : value
    }
    set {
      guard let newValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !newValue.isEmpty
      else {
        store.clear()
        return
      }
      store.save(accessToken: store.session?.accessToken ?? "", refreshToken: newValue)
    }
  }

  var hasRefreshToken: Bool { store.hasRefreshToken }

  func save(accessToken: String?, refreshToken: String) {
    store.save(accessToken: accessToken ?? "", refreshToken: refreshToken)
  }

  func clear() {
    store.clear()
  }
}



enum MediaSourceKind: String, Codable, Sendable {
  case webDAV
  case cloud115

  var title: String {
    switch self {
    case .webDAV: return "OpenList / AList"
    case .cloud115: return "115 网盘"
    }
  }

  var systemImage: String {
    switch self {
    case .webDAV: return "externaldrive.connected.to.line.below"
    case .cloud115: return "externaldrive.badge.icloud"
    }
  }
}

final class MediaSourceSelectionStore: @unchecked Sendable {
  static let shared = MediaSourceSelectionStore()

  private let key = "cineva.mediaSource.active.v1"
  private init() {}

  var activeSource: MediaSourceKind {
    get { .webDAV }
    set {
      // Keep the persisted key for downgrade compatibility, but Cineva now
      // deliberately uses OpenList/AList WebDAV as the active media source.
      UserDefaults.standard.set(MediaSourceKind.webDAV.rawValue, forKey: key)
    }
  }

  func isConfigured(_ source: MediaSourceKind) -> Bool {
    switch source {
    case .webDAV: return WebDAVCredentialStore.shared.isConfigured
    case .cloud115: return CredentialStore.shared.hasRefreshToken
    }
  }

  var resolvedSource: MediaSourceKind { .webDAV }
}

struct WebDAVMountConfiguration: Codable, Equatable, Sendable {
  let serverURL: String
  let username: String
  let password: String
  let rootPath: String

  init(serverURL: String, username: String, password: String, rootPath: String) {
    self.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    self.password = password
    self.rootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedRootPath: String {
    var value = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { value = "/115" }
    if !value.hasPrefix("/") { value = "/" + value }
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }

  var normalizedWebDAVURL: URL? {
    var input = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return nil }
    if !input.contains("://") { input = "https://" + input }
    guard var components = URLComponents(string: input),
      let scheme = components.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      components.host != nil
    else {
      return nil
    }

    var path = components.path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    if path.isEmpty || path == "/" {
      path = "/dav"
    } else if !path.lowercased().hasSuffix("/dav") {
      path += "/dav"
    }
    components.path = path + "/"
    components.query = nil
    components.fragment = nil
    return components.url
  }

  var webDAVBasePath: String {
    guard let url = normalizedWebDAVURL else { return "/dav" }
    var path = url.path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path.isEmpty ? "/dav" : path
  }

  var authorizationHeader: String? {
    guard !username.isEmpty || !password.isEmpty else { return nil }
    let raw = "\(username):\(password)"
    return "Basic \(Data(raw.utf8).base64EncodedString())"
  }

  var cacheNamespace: String {
    let host = normalizedWebDAVURL?.host ?? serverURL
    return "\(host)|\(username)|\(normalizedRootPath)"
  }
}

final class WebDAVCredentialStore: @unchecked Sendable {
  static let shared = WebDAVCredentialStore()

  private let service = "com.xiaocai.gallery115.webdav"
  private let account = "openlist-webdav-v1"
  private let lock = NSLock()

  private init() {}

  var configuration: WebDAVMountConfiguration? {
    lock.lock()
    defer { lock.unlock() }
    guard let data = readData() else { return nil }
    return try? JSONDecoder().decode(WebDAVMountConfiguration.self, from: data)
  }

  var isConfigured: Bool {
    guard let configuration else { return false }
    return configuration.normalizedWebDAVURL != nil
  }

  func save(_ configuration: WebDAVMountConfiguration) {
    guard configuration.normalizedWebDAVURL != nil else { return }
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    lock.lock()
    defer { lock.unlock() }
    writeData(data)
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func readData() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  private func writeData(_ data: Data) {
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = baseQuery
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      SecItemAdd(add as CFDictionary, nil)
    }
  }
}
