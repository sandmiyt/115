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



  enum BrowserLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
      switch self {
      case .grid: return "封面墙"
      case .list: return "列表"
      }
    }

    var icon: String {
      switch self {
      case .grid: return "square.grid.2x2"
      case .list: return "list.bullet"
      }
    }
  }

  enum ArtworkMode: String, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var title: String {
      switch self {
      case .fit: return "完整显示（推荐）"
      case .fill: return "铺满裁切"
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

  var artworkMode: ArtworkMode {
    didSet { UserDefaults.standard.set(artworkMode.rawValue, forKey: Keys.artworkMode) }
  }

  var browserLayout: BrowserLayout {
    didSet { UserDefaults.standard.set(browserLayout.rawValue, forKey: Keys.browserLayout) }
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

  var playerGesturesEnabled: Bool {
    didSet { UserDefaults.standard.set(playerGesturesEnabled, forKey: Keys.playerGesturesEnabled) }
  }

  var autoPlayNextEpisode: Bool {
    didSet { UserDefaults.standard.set(autoPlayNextEpisode, forKey: Keys.autoPlayNextEpisode) }
  }

  var doubleTapSeekSeconds: Int {
    didSet {
      if ![10, 15, 30].contains(doubleTapSeekSeconds) { doubleTapSeekSeconds = 15 }
      UserDefaults.standard.set(doubleTapSeekSeconds, forKey: Keys.doubleTapSeekSeconds)
    }
  }

  init() {
    let defaults = UserDefaults.standard
    let storedColumns = defaults.object(forKey: Keys.gridColumns) as? Int ?? 3
    if defaults.bool(forKey: Keys.compactArtworkMigration) == false {
      gridColumns = storedColumns == 2 ? 3 : min(max(storedColumns, 2), 4)
      defaults.set(true, forKey: Keys.compactArtworkMigration)
    } else {
      gridColumns = min(max(storedColumns, 2), 4)
    }
    artworkMode =
      ArtworkMode(rawValue: defaults.string(forKey: Keys.artworkMode) ?? "") ?? .fit
    browserLayout =
      BrowserLayout(rawValue: defaults.string(forKey: Keys.browserLayout) ?? "") ?? .grid
    defaultQuality =
      DefaultQuality(rawValue: defaults.string(forKey: Keys.defaultQuality) ?? "")
      ?? .highestTranscode
    colorSchemePreference =
      ColorSchemePreference(rawValue: defaults.string(forKey: Keys.colorScheme) ?? "") ?? .system
    rootFolderID = defaults.string(forKey: Keys.rootFolderID) ?? "0"
    faceIDEnabled = defaults.bool(forKey: Keys.faceIDEnabled)
    playerGesturesEnabled = defaults.object(forKey: Keys.playerGesturesEnabled) as? Bool ?? true
    autoPlayNextEpisode = defaults.object(forKey: Keys.autoPlayNextEpisode) as? Bool ?? true
    let storedSeek = defaults.object(forKey: Keys.doubleTapSeekSeconds) as? Int ?? 15
    doubleTapSeekSeconds = [10, 15, 30].contains(storedSeek) ? storedSeek : 15
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
    return await authenticate(reason: "验证身份后进入 Cineva")
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
    static let artworkMode = "gallery115.artworkMode"
    static let browserLayout = "gallery115.browserLayout"
    static let compactArtworkMigration = "cineva.compactArtworkMigration.v1"
    static let defaultQuality = "gallery115.defaultQuality"
    static let colorScheme = "gallery115.colorScheme"
    static let rootFolderID = "gallery115.rootFolderID"
    static let faceIDEnabled = "gallery115.faceIDEnabled"
    static let playerGesturesEnabled = "gallery115.playerGesturesEnabled"
    static let autoPlayNextEpisode = "gallery115.autoPlayNextEpisode"
    static let doubleTapSeekSeconds = "gallery115.doubleTapSeekSeconds"
  }
}
