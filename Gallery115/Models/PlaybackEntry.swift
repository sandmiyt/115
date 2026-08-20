import Foundation

struct PlaybackEntry: Codable, Hashable, Identifiable {
  let item: CloudItem
  var lastPosition: Double
  var lastPlayedAt: Date
  var knownDuration: Double?

  var id: String { item.id }

  var effectiveDuration: Double {
    let value = knownDuration ?? item.duration
    return value.isFinite ? max(value, 0) : 0
  }
}
