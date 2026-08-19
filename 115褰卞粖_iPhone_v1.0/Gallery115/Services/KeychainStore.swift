import Foundation
import Security

final class CredentialStore: @unchecked Sendable {
  static let shared = CredentialStore()

  private let service = "com.xiaocai.gallery115.credentials"
  private let accessAccount = "access-token"
  private let refreshAccount = "refresh-token"

  private init() {}

  var accessToken: String? {
    get { read(account: accessAccount) }
    set { write(newValue, account: accessAccount) }
  }

  var refreshToken: String? {
    get { read(account: refreshAccount) }
    set { write(newValue, account: refreshAccount) }
  }

  var hasRefreshToken: Bool {
    guard let refreshToken else { return false }
    return !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func save(accessToken: String?, refreshToken: String) {
    self.accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func clear() {
    accessToken = nil
    refreshToken = nil
  }

  private func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return value
  }

  private func write(_ value: String?, account: String) {
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    guard let value, !value.isEmpty else {
      SecItemDelete(baseQuery as CFDictionary)
      return
    }

    let data = Data(value.utf8)
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
