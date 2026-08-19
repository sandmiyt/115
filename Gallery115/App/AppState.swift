import Foundation
import LocalAuthentication
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
  enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
      switch self {
      case .system: return "跟随系统"
      case .light: return "浅色"
      case .dark: return "深色"
      }
    }

    var colorScheme: ColorScheme? {
      switch self {
      case .system: return nil
      case .light: return .light
      case .dark: return .dark
      }
    }
  }

  enum DefaultQuality: String, CaseIterable, Identifiable {
    case highestTranscode
    case original

    var id: String { rawValue }

    var title: String {
      switch self {
      case .highestTranscode: return "最高转码（推荐）"
      case .original: return "原画优先"
      }
    }
  }

  let api = APIClient()
  let thumbnailService = ThumbnailService()
  let libraryStore = LibraryStore()

  var isConfigured = CredentialStore.shared.hasRefreshToken
  var biometricErrorMessage: String?
  private(set) var isAppUnlocked: Bool
  private var biometricAuthenticationInProgress = false

  var gridColumns: Int {
    didSet {
      gridColumns = min(max(gridColumns, 2), 4)
      UserDefaults.standard.set(gridColumns, forKey: Keys.gridColumns)
    }
  }

  var defaultQuality: DefaultQuality {
    didSet { UserDefaults.standard.set(defaultQuality.rawValue, forKey: Keys.defaultQuality) }
  }

  var colorSchemePreference: ColorSchemePreference {
    didSet { UserDefaults.standard.set(colorSchemePreference.rawValue, forKey: Keys.colorScheme) }
  }

  var rootFolderID: String {
    didSet { UserDefaults.standard.set(rootFolderID, forKey: Keys.rootFolderID) }
  }

  var faceIDEnabled: Bool {
    didSet { UserDefaults.standard.set(faceIDEnabled, forKey: Keys.faceIDEnabled) }
  }

  init() {
    let defaults = UserDefaults.standard
    let storedColumns = defaults.object(forKey: Keys.gridColumns) as? Int ?? 2
    gridColumns = min(max(storedColumns, 2), 4)
    defaultQuality =
      DefaultQuality(rawValue: defaults.string(forKey: Keys.defaultQuality) ?? "")
      ?? .highestTranscode
    colorSchemePreference =
      ColorSchemePreference(rawValue: defaults.string(forKey: Keys.colorScheme) ?? "") ?? .system
    rootFolderID = defaults.string(forKey: Keys.rootFolderID) ?? "0"
    faceIDEnabled = defaults.bool(forKey: Keys.faceIDEnabled)
    isAppUnlocked = !defaults.bool(forKey: Keys.faceIDEnabled)
  }

  func finishConfiguration(rootFolderID: String) {
    self.rootFolderID = rootFolderID.isEmpty ? "0" : rootFolderID
    isConfigured = true
    isAppUnlocked = true
  }

  func signOut() {
    CredentialStore.shared.clear()
    libraryStore.clearSensitiveSessionData()
    isConfigured = false
    isAppUnlocked = true
  }

  func lockForBackground() {
    guard isConfigured, faceIDEnabled else { return }
    isAppUnlocked = false
    biometricErrorMessage = nil
  }

  @discardableResult
  func authenticateIfNeeded() async -> Bool {
    guard isConfigured, faceIDEnabled else {
      isAppUnlocked = true
      return true
    }
    guard !isAppUnlocked else { return true }
    return await authenticate(reason: "验证身份后进入“影”")
  }

  @discardableResult
  func setFaceIDProtection(_ enabled: Bool) async -> Bool {
    biometricErrorMessage = nil

    if !enabled {
      faceIDEnabled = false
      isAppUnlocked = true
      return true
    }

    let success = await authenticate(reason: "开启面容 ID 保护")
    if success {
      faceIDEnabled = true
      isAppUnlocked = true
    }
    return success
  }

  var canUseBiometrics: Bool {
    let context = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
  }

  var biometricTitle: String {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
      return "生物识别"
    }
    switch context.biometryType {
    case .faceID: return "面容 ID"
    case .touchID: return "触控 ID"
    case .opticID: return "Optic ID"
    default: return "生物识别"
    }
  }

  private func authenticate(reason: String) async -> Bool {
    if biometricAuthenticationInProgress {
      return isAppUnlocked
    }
    biometricAuthenticationInProgress = true
    defer { biometricAuthenticationInProgress = false }

    let context = LAContext()
    context.localizedCancelTitle = "取消"

    var authError: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
      biometricErrorMessage = authError?.localizedDescription ?? "此设备暂时无法使用生物识别。"
      isAppUnlocked = false
      return false
    }

    do {
      let success = try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: reason
      )
      isAppUnlocked = success
      biometricErrorMessage = nil
      return success
    } catch {
      biometricErrorMessage = error.localizedDescription
      isAppUnlocked = false
      return false
    }
  }

  private enum Keys {
    static let gridColumns = "gallery115.gridColumns"
    static let defaultQuality = "gallery115.defaultQuality"
    static let colorScheme = "gallery115.colorScheme"
    static let rootFolderID = "gallery115.rootFolderID"
    static let faceIDEnabled = "gallery115.faceIDEnabled"
  }
}
