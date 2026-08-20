import Foundation
import Security

struct Cloud115Session: Codable, Equatable, Sendable {
  let accessToken: String
  let refreshToken: String
  let updatedAt: Date

  init(accessToken: String, refreshToken: String, updatedAt: Date = Date()) {
    self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.updatedAt = updatedAt
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

  func save(accessToken: String, refreshToken: String) {
    save(Cloud115Session(accessToken: accessToken, refreshToken: refreshToken))
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
