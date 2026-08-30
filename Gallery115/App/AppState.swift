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
      case .unknown: return "OpenList · WebDAV"
      case .connected: return "OpenList · 已连接"
      case .cache: return "OpenList · 缓存"
      case .offline: return "OpenList · 离线"
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
  // Entering the background should not launch Face ID while the user is
  // watching Picture in Picture. Instead, remember that the next foreground
  // activation must lock and authenticate before content is revealed.
  private var requiresAuthenticationAfterBackground = false

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

  var autoLoadExternalSubtitle: Bool {
    didSet { UserDefaults.standard.set(autoLoadExternalSubtitle, forKey: Keys.autoLoadExternalSubtitle) }
  }

  var autoLoadExternalSubtitles: Bool {
    get { autoLoadExternalSubtitle }
    set { autoLoadExternalSubtitle = newValue }
  }

  var subtitleFontScale: Double {
    didSet { UserDefaults.standard.set(min(max(subtitleFontScale, 0.8), 1.6), forKey: Keys.subtitleFontScale) }
  }

  var subtitleBottomPadding: Double {
    didSet { UserDefaults.standard.set(min(max(subtitleBottomPadding, 0.04), 0.28), forKey: Keys.subtitleBottomPadding) }
  }

  var subtitleDelaySeconds: Double {
    didSet { UserDefaults.standard.set(min(max(subtitleDelaySeconds, -10), 10), forKey: Keys.subtitleDelaySeconds) }
  }

  var subtitleTimeOffset: Double {
    get { subtitleDelaySeconds }
    set { subtitleDelaySeconds = newValue }
  }

  var chapterMarksEnabled: Bool {
    didSet { UserDefaults.standard.set(chapterMarksEnabled, forKey: Keys.chapterMarksEnabled) }
  }

  var showChapterMarkers: Bool {
    get { chapterMarksEnabled }
    set { chapterMarksEnabled = newValue }
  }

  var skipIntroEnabled: Bool {
    didSet { UserDefaults.standard.set(skipIntroEnabled, forKey: Keys.skipIntroEnabled) }
  }

  var introSkipSeconds: Int {
    didSet { UserDefaults.standard.set(min(max(introSkipSeconds, 10), 300), forKey: Keys.introSkipSeconds) }
  }

  var skipOutroEnabled: Bool {
    didSet { UserDefaults.standard.set(skipOutroEnabled, forKey: Keys.skipOutroEnabled) }
  }

  var outroSkipSeconds: Int {
    didSet { UserDefaults.standard.set(min(max(outroSkipSeconds, 10), 600), forKey: Keys.outroSkipSeconds) }
  }

  var outroPromptSeconds: Int {
    get { outroSkipSeconds }
    set { outroSkipSeconds = newValue }
  }

  var progressPreviewEnabled: Bool {
    didSet { UserDefaults.standard.set(progressPreviewEnabled, forKey: Keys.progressPreviewEnabled) }
  }

  var timelinePreviewEnabled: Bool {
    get { progressPreviewEnabled }
    set { progressPreviewEnabled = newValue }
  }

  var networkAutoRecoveryEnabled: Bool {
    didSet { UserDefaults.standard.set(networkAutoRecoveryEnabled, forKey: Keys.networkAutoRecoveryEnabled) }
  }

  var fastStartEnabled: Bool {
    didSet { UserDefaults.standard.set(fastStartEnabled, forKey: Keys.fastStartEnabled) }
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
    let source = sourceStore.resolvedSource
    mediaSourceKind = source
    isConfigured = sourceStore.isConfigured(source)
    switch source {
    case .cloud115:
      rootFolderID = "0"
    case .webDAV:
      rootFolderID = WebDAVCredentialStore.shared.configuration?.normalizedRootPath
        ?? defaults.string(forKey: Keys.rootFolderID)
        ?? "/115"
    }
    faceIDEnabled = defaults.bool(forKey: Keys.faceIDEnabled)
    playerGesturesEnabled = defaults.object(forKey: Keys.playerGesturesEnabled) as? Bool ?? true
    autoPlayNextEpisode = defaults.object(forKey: Keys.autoPlayNextEpisode) as? Bool ?? true
    autoLoadExternalSubtitle = defaults.object(forKey: Keys.autoLoadExternalSubtitle) as? Bool ?? true
    subtitleFontScale = min(max(defaults.object(forKey: Keys.subtitleFontScale) as? Double ?? 1.0, 0.8), 1.6)
    subtitleBottomPadding = min(max(defaults.object(forKey: Keys.subtitleBottomPadding) as? Double ?? 0.10, 0.04), 0.28)
    subtitleDelaySeconds = min(max(defaults.object(forKey: Keys.subtitleDelaySeconds) as? Double ?? 0, -10), 10)
    chapterMarksEnabled = defaults.object(forKey: Keys.chapterMarksEnabled) as? Bool ?? true
    skipIntroEnabled = defaults.object(forKey: Keys.skipIntroEnabled) as? Bool ?? false
    introSkipSeconds = min(max(defaults.object(forKey: Keys.introSkipSeconds) as? Int ?? 90, 10), 300)
    skipOutroEnabled = defaults.object(forKey: Keys.skipOutroEnabled) as? Bool ?? false
    outroSkipSeconds = min(max(defaults.object(forKey: Keys.outroSkipSeconds) as? Int ?? 120, 10), 600)
    progressPreviewEnabled = defaults.object(forKey: Keys.progressPreviewEnabled) as? Bool ?? true
    networkAutoRecoveryEnabled = defaults.object(forKey: Keys.networkAutoRecoveryEnabled) as? Bool ?? true
    fastStartEnabled = defaults.object(forKey: Keys.fastStartEnabled) as? Bool ?? true
    let storedRate = defaults.object(forKey: Keys.preferredPlaybackRate) as? Double ?? 1.0
    preferredPlaybackRate = Float(min(max(storedRate, 0.5), 2.0))
    let storedSeek = defaults.object(forKey: Keys.doubleTapSeekSeconds) as? Int ?? 15
    doubleTapSeekSeconds = [10, 15, 30].contains(storedSeek) ? storedSeek : 15
    isAppUnlocked = !defaults.bool(forKey: Keys.faceIDEnabled)
  }

  func finishConfiguration(source: MediaSourceKind, rootFolderID: String) {
    MediaSourceSelectionStore.shared.activeSource = source
    mediaSourceKind = source
    let trimmed = rootFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
    switch source {
    case .cloud115:
      self.rootFolderID = trimmed.isEmpty ? "0" : trimmed
    case .webDAV:
      self.rootFolderID = trimmed.isEmpty ? "/115" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
    }
    isConfigured = MediaSourceSelectionStore.shared.isConfigured(source)
    isAppUnlocked = true
    mediaConnectionState = .unknown
    Task {
      await api.clearAllMountCaches()
      await thumbnailService.resetForSourceChange()
    }
  }

  func finishConfiguration(rootFolderID: String) {
    finishConfiguration(
      source: MediaSourceSelectionStore.shared.resolvedSource,
      rootFolderID: rootFolderID
    )
  }

  func signOut() {
    let disconnectedSource = mediaSourceKind
    switch disconnectedSource {
    case .webDAV:
      WebDAVCredentialStore.shared.clear()
    case .cloud115:
      Cloud115SessionStore.shared.clear()
    }
    libraryStore.clearSensitiveSessionData()
    let sourceStore = MediaSourceSelectionStore.shared
    let fallback: MediaSourceKind? = {
      switch disconnectedSource {
      case .cloud115: return sourceStore.isConfigured(.webDAV) ? .webDAV : nil
      case .webDAV: return sourceStore.isConfigured(.cloud115) ? .cloud115 : nil
      }
    }()
    if let fallback {
      sourceStore.activeSource = fallback
      mediaSourceKind = fallback
      rootFolderID = fallback == .cloud115
        ? "0"
        : (WebDAVCredentialStore.shared.configuration?.normalizedRootPath ?? "/115")
      isConfigured = true
    } else {
      isConfigured = false
    }
    Task {
      await api.clearAllMountCaches()
      await thumbnailService.resetForSourceChange()
    }
    isAppUnlocked = true
    requiresAuthenticationAfterBackground = false
    mediaConnectionState = .unknown
  }

  func lockForBackground() {
    guard isConfigured, faceIDEnabled else {
      requiresAuthenticationAfterBackground = false
      return
    }

    // Do not flip isAppUnlocked here. A full-screen player may be entering
    // Picture in Picture at the same moment, and changing the lock state while
    // the app is backgrounding can cause biometric authentication to appear on
    // top of the Home Screen. The window privacy shield already protects the
    // app-switcher snapshot while we are away.
    requiresAuthenticationAfterBackground = true
    biometricErrorMessage = nil
  }

  /// Moves a deferred background lock into the visible locked state. Call this
  /// only after the scene becomes active again. This guarantees that returning
  /// from the Home Screen or Picture in Picture still requires Face ID, without
  /// presenting Face ID while the user remains outside Cineva.
  func prepareForForegroundAuthentication() {
    guard requiresAuthenticationAfterBackground else { return }
    requiresAuthenticationAfterBackground = false

    guard isConfigured, faceIDEnabled else {
      isAppUnlocked = true
      return
    }

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
      requiresAuthenticationAfterBackground = false
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
    switch mediaConnectionState {
    case .unknown: return "OpenList · 已挂载"
    case .connected: return "OpenList · 已连接"
    case .cache: return "OpenList · 缓存"
    case .offline: return "OpenList · 离线"
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
    context.localizedFallbackTitle = "输入密码"
    let policy: LAPolicy = .deviceOwnerAuthentication

    var authError: NSError?
    guard context.canEvaluatePolicy(policy, error: &authError) else {
      biometricErrorMessage = authError?.localizedDescription ?? "此设备暂时无法验证身份。"
      isAppUnlocked = false
      return false
    }

    do {
      let success = try await context.evaluatePolicy(
        policy,
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
    static let autoLoadExternalSubtitle = "cineva.subtitle.autoLoadExternal.v1"
    static let subtitleFontScale = "cineva.subtitle.fontScale.v1"
    static let subtitleBottomPadding = "cineva.subtitle.bottomPadding.v1"
    static let subtitleDelaySeconds = "cineva.subtitle.delay.v1"
    static let chapterMarksEnabled = "cineva.playback.chapterMarks.v1"
    static let skipIntroEnabled = "cineva.playback.skipIntro.v1"
    static let introSkipSeconds = "cineva.playback.introSeconds.v1"
    static let skipOutroEnabled = "cineva.playback.skipOutro.v1"
    static let outroSkipSeconds = "cineva.playback.outroSeconds.v1"
    static let progressPreviewEnabled = "cineva.playback.progressPreview.v1"
    static let networkAutoRecoveryEnabled = "cineva.network.autoRecovery.v1"
    static let fastStartEnabled = "cineva.playback.fastStart.v1"
    static let doubleTapSeekSeconds = "gallery115.doubleTapSeekSeconds"
  }
}
