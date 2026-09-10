import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
  private(set) var favorites: [CloudItem] = []
  private(set) var recents: [PlaybackEntry] = []

  private let defaults: UserDefaults
  @ObservationIgnored private var favoriteIDs = Set<String>()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    load()
  }

  func isFavorite(_ item: CloudItem) -> Bool {
    _ = favorites.count // Register the observable collection dependency.
    return favoriteIDs.contains(item.id)
  }

  func toggleFavorite(_ item: CloudItem) {
    setFavorites([item], enabled: !isFavorite(item))
  }

  /// One collection publication and one write for an entire selection.
  func setFavorites(_ items: [CloudItem], enabled: Bool) {
    let media = items.filter { !$0.isDirectory && ($0.isVideo || $0.isPhoto) }
    let ids = Set(media.map(\.id))
    let updated: [CloudItem]
    if enabled {
      var seen = favoriteIDs
      let additions = media.filter { seen.insert($0.id).inserted }
      updated = additions + favorites
    } else {
      updated = favorites.filter { !ids.contains($0.id) }
    }
    guard updated != favorites else { return }
    favorites = updated
    persistFavorites()
  }

  func reconcileFavorites(with items: [CloudItem]) {
    let updated = FavoriteRelocationPolicy.reconciled(favorites, with: items)
    guard updated != favorites else { return }
    favorites = updated
    persistFavorites()
  }

  func recordPlayback(_ item: CloudItem, position: Double, duration: Double? = nil) {
    let normalizedDuration: Double? = {
      guard let duration, duration.isFinite, duration > 0 else { return nil }
      return duration
    }()

    if let index = recents.firstIndex(where: { $0.item.id == item.id }) {
      recents[index].lastPosition = max(0, position)
      recents[index].lastPlayedAt = Date()
      if let normalizedDuration { recents[index].knownDuration = normalizedDuration }
      let entry = recents.remove(at: index)
      recents.insert(entry, at: 0)
    } else {
      recents.insert(
        PlaybackEntry(
          item: item,
          lastPosition: max(0, position),
          lastPlayedAt: Date(),
          knownDuration: normalizedDuration
        ),
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

  func knownDuration(for item: CloudItem) -> Double {
    recents.first(where: { $0.item.id == item.id })?.effectiveDuration ?? max(item.duration, 0)
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
      favoriteIDs = Set(decoded.map(\.id))
    }
    if let data = defaults.data(forKey: Keys.recents),
      let decoded = try? decoder.decode([PlaybackEntry].self, from: data)
    {
      recents = decoded.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }
  }

  private func persistFavorites() {
    favoriteIDs = Set(favorites.map(\.id))
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
