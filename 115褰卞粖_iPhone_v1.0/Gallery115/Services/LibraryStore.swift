import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
  private(set) var favorites: [CloudItem] = []
  private(set) var recents: [PlaybackEntry] = []

  private let defaults = UserDefaults.standard
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init() {
    load()
  }

  func isFavorite(_ item: CloudItem) -> Bool {
    favorites.contains { $0.id == item.id }
  }

  func toggleFavorite(_ item: CloudItem) {
    if let index = favorites.firstIndex(where: { $0.id == item.id }) {
      favorites.remove(at: index)
    } else {
      favorites.insert(item, at: 0)
    }
    persistFavorites()
  }

  func recordPlayback(_ item: CloudItem, position: Double) {
    if let index = recents.firstIndex(where: { $0.item.id == item.id }) {
      recents[index].lastPosition = max(0, position)
      recents[index].lastPlayedAt = Date()
      let entry = recents.remove(at: index)
      recents.insert(entry, at: 0)
    } else {
      recents.insert(
        PlaybackEntry(item: item, lastPosition: max(0, position), lastPlayedAt: Date()),
        at: 0
      )
    }
    if recents.count > 100 {
      recents.removeLast(recents.count - 100)
    }
    persistRecents()
  }

  func resumePosition(for item: CloudItem) -> Double {
    recents.first(where: { $0.item.id == item.id })?.lastPosition ?? 0
  }

  func clearRecents() {
    recents = []
    persistRecents()
  }

  func clearSensitiveSessionData() {
    // Favorites and recents are local-only metadata and intentionally remain.
  }

  private func load() {
    if let data = defaults.data(forKey: Keys.favorites),
      let decoded = try? decoder.decode([CloudItem].self, from: data)
    {
      favorites = decoded
    }
    if let data = defaults.data(forKey: Keys.recents),
      let decoded = try? decoder.decode([PlaybackEntry].self, from: data)
    {
      recents = decoded.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }
  }

  private func persistFavorites() {
    if let data = try? encoder.encode(favorites) {
      defaults.set(data, forKey: Keys.favorites)
    }
  }

  private func persistRecents() {
    if let data = try? encoder.encode(recents) {
      defaults.set(data, forKey: Keys.recents)
    }
  }

  private enum Keys {
    static let favorites = "gallery115.favorites.v1"
    static let recents = "gallery115.recents.v1"
  }
}
