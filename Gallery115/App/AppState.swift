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

  enum MediaConnectionState: Equatable {
    case unknown
    case connected
    case cache
    case offline

    var title: String {
      switch self {
      case .unknown: return "115 · 未检测"
      case .connected: return "115 · 已连接"
      case .cache: return "115 · 缓存"
      case .offline: return "115 · 离线"
      }
    }

    var systemImage: String {
      switch self {
      case .unknown: return "externaldrive.connected.to.line.below"
      case .connected: return "checkmark.circle.fill"
      case .cache: return "externaldrive.badge.checkmark"
      case .offline: return "wifi.slash"
      }
    }
  }

  let api = APIClient()
  let thumbnailService = ThumbnailService()
  let libraryStore = LibraryStore()

  private(set) var mediaSourceKind: MediaSourceKind
  var isConfigured: Bool
  var biometricErrorMessage: String?
  private(set) var isAppUnlocked: Bool
  private var biometricAuthenticationInProgress = false

  private var storedGridColumns: Int
  var gridColumns: Int {
    get { storedGridColumns }
    set {
      let clamped = min(max(newValue, 2), 4)
      guard storedGridColumns != clamped else { return }
      storedGridColumns = clamped
      UserDefaults.standard.set(clamped, forKey: Keys.gridColumns)
    }
  }

  var preferredPlaybackRate: Float {
    didSet {
      let safeRate = min(max(preferredPlaybackRate, 0.5), 2.0)
      if preferredPlaybackRate != safeRate {
        preferredPlaybackRate = safeRate
        return
      }
      UserDefaults.standard.set(Double(preferredPlaybackRate), forKey: Keys.preferredPlaybackRate)
    }
  }

  var mediaConnectionState: MediaConnectionState = .unknown

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
      storedGridColumns = storedColumns == 2 ? 3 : min(max(storedColumns, 2), 4)
      defaults.set(true, forKey: Keys.compactArtworkMigration)
    } else {
      storedGridColumns = min(max(storedColumns, 2), 4)
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
    let sourceStore = MediaSourceSelectionStore.shared
    let resolvedSource = sourceStore.resolvedSource
    mediaSourceKind = resolvedSource
    isConfigured = sourceStore.isConfigured(resolvedSource)
    switch resolvedSource {
    case .cloud115:
      rootFolderID = "0"
    case .webDAV:
      rootFolderID = WebDAVCredentialStore.shared.configuration?.normalizedRootPath
        ?? defaults.string(forKey: Keys.rootFolderID)
        ?? "/115"
    }
    let storedFaceIDEnabled = defaults.object(forKey: Keys.faceIDEnabled) as? Bool
    faceIDEnabled = storedFaceIDEnabled ?? Self.deviceSupportsBiometrics()
    playerGesturesEnabled = defaults.object(forKey: Keys.playerGesturesEnabled) as? Bool ?? true
    autoPlayNextEpisode = defaults.object(forKey: Keys.autoPlayNextEpisode) as? Bool ?? true
    let storedRate = defaults.object(forKey: Keys.preferredPlaybackRate) as? Double ?? 1.0
    preferredPlaybackRate = Float(min(max(storedRate, 0.5), 2.0))
    let storedSeek = defaults.object(forKey: Keys.doubleTapSeekSeconds) as? Int ?? 15
    doubleTapSeekSeconds = [10, 15, 30].contains(storedSeek) ? storedSeek : 15
    isAppUnlocked = !faceIDEnabled
  }

  func finishConfiguration(source: MediaSourceKind, rootFolderID: String) {
    MediaSourceSelectionStore.shared.activeSource = source
    mediaSourceKind = source

    switch source {
    case .cloud115:
      self.rootFolderID = "0"
    case .webDAV:
      let trimmed = rootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
      self.rootFolderID = trimmed.isEmpty ? "/115" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
    }

    isConfigured = MediaSourceSelectionStore.shared.isConfigured(source)
    mediaConnectionState = .unknown
  }

  func finishConfiguration(rootFolderID: String) {
    finishConfiguration(
      source: MediaSourceSelectionStore.shared.resolvedSource,
      rootFolderID: rootFolderID
    )
  }

  func signOut() {
    switch mediaSourceKind {
    case .webDAV:
      WebDAVCredentialStore.shared.clear()
    case .cloud115:
      CredentialStore.shared.clear()
    }
    libraryStore.clearSensitiveSessionData()
    Task { await api.clearMountCache() }
    isConfigured = false
    mediaConnectionState = .unknown
  }

  func lockForBackground() {
    guard faceIDEnabled else { return }
    isAppUnlocked = false
    biometricErrorMessage = nil
  }

  @discardableResult
  func authenticateIfNeeded() async -> Bool {
    guard faceIDEnabled else {
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

  var mediaConnectionTitle: String {
    let source = mediaSourceKind == .cloud115 ? "115" : "OpenList"
    switch mediaConnectionState {
    case .unknown: return "\(source) · 已挂载"
    case .connected: return "\(source) · 已连接"
    case .cache: return "\(source) · 缓存"
    case .offline: return "\(source) · 离线"
    }
  }

  func markMediaConnected() {
    mediaConnectionState = .connected
  }

  func markMediaUsingCache() {
    if mediaConnectionState != .offline {
      mediaConnectionState = .cache
    }
  }

  func markMediaOffline() {
    mediaConnectionState = .offline
  }

  private static func deviceSupportsBiometrics() -> Bool {
    let context = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
  }

  var canUseBiometrics: Bool {
    Self.deviceSupportsBiometrics()
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
    static let preferredPlaybackRate = "cineva.player.playbackRate.v1"
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
