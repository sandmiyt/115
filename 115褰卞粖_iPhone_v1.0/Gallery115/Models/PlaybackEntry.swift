import Foundation

struct PlaybackEntry: Codable, Hashable, Identifiable {
  let item: CloudItem
  var lastPosition: Double
  var lastPlayedAt: Date

  var id: String { item.id }
}
