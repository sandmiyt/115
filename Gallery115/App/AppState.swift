import Foundation
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
  }

  func finishConfiguration(rootFolderID: String) {
    self.rootFolderID = rootFolderID.isEmpty ? "0" : rootFolderID
    isConfigured = true
  }

  func signOut() {
    CredentialStore.shared.clear()
    libraryStore.clearSensitiveSessionData()
    isConfigured = false
  }

  private enum Keys {
    static let gridColumns = "gallery115.gridColumns"
    static let defaultQuality = "gallery115.defaultQuality"
    static let colorScheme = "gallery115.colorScheme"
    static let rootFolderID = "gallery115.rootFolderID"
  }
}
