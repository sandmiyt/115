import Foundation

struct LibraryFolderSnapshot {
  let items: [CloudItem]
  let nextOffset: Int
  let hasMore: Bool
}

struct MediaScrollRequest: Equatable {
  let id = UUID()
  let itemID: String
}

struct PlaybackBufferRange: Equatable, Sendable {
  let start: Double
  let end: Double
}

enum PlaybackBufferPolicy {
  /// A compressed-data estimate, not a hard AVFoundation memory limit.
  /// Keep a longer runway on bursty connections without requesting minutes of
  /// a very high bitrate original. Decoded frames are managed by AVFoundation.
  static func forwardDuration(bitrate: Double, stalls: Int, rate: Double) -> Double {
    let desired = min(90, 30 + Double(min(max(stalls, 0), 3)) * 20) * max(rate, 1)
    let budgetSeconds = bitrate.isFinite && bitrate > 0 ? 64 * 1_048_576 * 8 / bitrate : 60
    return min(desired, max(8, budgetSeconds))
  }

  static func normalized(_ ranges: [PlaybackBufferRange]) -> [PlaybackBufferRange] {
    let sorted = ranges.filter { $0.start.isFinite && $0.end.isFinite && $0.end > max(0, $0.start) }
      .sorted { $0.start < $1.start }
    var result: [PlaybackBufferRange] = []
    for range in sorted {
      let start = max(0, range.start)
      if let last = result.last, start <= last.end {
        result[result.count - 1] = PlaybackBufferRange(start: last.start, end: max(last.end, range.end))
      } else {
        result.append(PlaybackBufferRange(start: start, end: range.end))
      }
    }
    return result
  }

  static func contiguousEnd(at time: Double, ranges: [PlaybackBufferRange]) -> Double {
    ranges.first { $0.start <= time && time < $0.end }?.end ?? time
  }
}

enum MediaDragSelectionPolicy {
  static func selection(items: [CloudItem], baseline: Set<String>, start: Int, end: Int, adding: Bool) -> Set<String> {
    guard items.indices.contains(start), items.indices.contains(end) else { return baseline }
    let ids = Set(items[min(start, end)...max(start, end)].filter(\.isVideo).map(\.id))
    return adding ? baseline.union(ids) : baseline.subtracting(ids)
  }
}

struct CloudItem: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let parentID: String
  let name: String
  let isDirectory: Bool
  let pickCode: String
  let sha1: String
  let size: Int64
  let fileExtension: String
  let isVideo: Bool
  let duration: Double
  let thumbnailURLString: String?
  let modifiedAt: Date
  let createdAt: Date?

  init(
    id: String,
    parentID: String,
    name: String,
    isDirectory: Bool,
    pickCode: String,
    sha1: String,
    size: Int64,
    fileExtension: String,
    isVideo: Bool,
    duration: Double,
    thumbnailURLString: String?,
    modifiedAt: Date,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.parentID = parentID
    self.name = name
    self.isDirectory = isDirectory
    self.pickCode = pickCode
    self.sha1 = sha1
    self.size = size
    self.fileExtension = fileExtension
    self.isVideo = isVideo
    self.duration = duration
    self.thumbnailURLString = thumbnailURLString
    self.modifiedAt = modifiedAt
    self.createdAt = createdAt
  }

  /// WebDAV creation time is the closest standard signal for when an item was
  /// added to OpenList. Older servers omit it, so modification time remains the
  /// compatible fallback.
  var librarySortDate: Date { createdAt ?? modifiedAt }

  var thumbnailURL: URL? {
    guard let thumbnailURLString, !thumbnailURLString.isEmpty else { return nil }
    return URL(string: thumbnailURLString)
  }

  var formattedSize: String {
    guard !isDirectory else { return "文件夹" }
    return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }

  var formattedDuration: String {
    guard duration > 0 else { return "" }
    let total = Int(duration.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  var isPhoto: Bool {
    Self.photoExtensions.contains(fileExtension.lowercased())
  }

  var isDiscImage: Bool {
    ["iso", "img"].contains(fileExtension.lowercased())
  }

  var prefersVLCForOriginal: Bool {
    let ext = fileExtension.lowercased()
    return ["mkv", "avi", "flv", "rmvb", "wmv", "m2ts", "mts", "ts", "webm", "iso", "img"].contains(ext)
  }

  private static let photoExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "avif",
  ]
}

enum CloudItemSortOrder: String, CaseIterable, Sendable {
  case updated
  case oldest
  case name
  case size
  case sizeAscending
}

/// Keeps a paged media collection stable while more rows arrive.
///
/// Sorting the whole collection after every page can insert new cells above the
/// visible viewport. Lazy grids then restore their anchor against a different
/// layout, which feels like the library has jumped backwards. Initial/manual
/// snapshots are fully ordered; incremental pages are ordered internally and
/// appended without moving cells the user is already looking at.
enum CloudItemCollectionPolicy {
  static func ordered(_ items: [CloudItem], by order: CloudItemSortOrder) -> [CloudItem] {
    var seen = Set<String>()
    return items
      .filter { seen.insert($0.id).inserted }
      .sorted { comesBefore($0, $1, by: order) }
  }

  static func appendingPage(
    _ page: [CloudItem],
    to current: [CloudItem],
    by order: CloudItemSortOrder
  ) -> [CloudItem] {
    var seen = Set(current.map(\.id))
    let additions = ordered(page.filter { seen.insert($0.id).inserted }, by: order)
    return current + additions
  }

  /// A silent first-page refresh is only a partial snapshot. Update matching
  /// models in place and append new IDs, but never delete or reorder cells that
  /// may currently be anchoring the scroll view. A manual refresh still replaces
  /// the complete collection and therefore remains authoritative for deletions.
  static func mergingFirstPage(
    _ refreshed: [CloudItem],
    into current: [CloudItem],
    by order: CloudItemSortOrder
  ) -> [CloudItem] {
    let latestByID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    var seen = Set<String>()
    var merged = current.compactMap { item -> CloudItem? in
      guard seen.insert(item.id).inserted else { return nil }
      return latestByID[item.id] ?? item
    }
    let additions = ordered(refreshed.filter { seen.insert($0.id).inserted }, by: order)
    merged.append(contentsOf: additions)
    return merged
  }

  private static func comesBefore(
    _ lhs: CloudItem,
    _ rhs: CloudItem,
    by order: CloudItemSortOrder
  ) -> Bool {
    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }

    switch order {
    case .updated:
      if lhs.librarySortDate != rhs.librarySortDate { return lhs.librarySortDate > rhs.librarySortDate }
    case .oldest:
      if lhs.librarySortDate != rhs.librarySortDate { return lhs.librarySortDate < rhs.librarySortDate }
    case .name:
      let comparison = lhs.name.localizedStandardCompare(rhs.name)
      if comparison != .orderedSame { return comparison == .orderedAscending }
    case .size:
      if lhs.size != rhs.size { return lhs.size > rhs.size }
    case .sizeAscending:
      if lhs.size != rhs.size { return lhs.size < rhs.size }
    }

    // A total tie-breaker prevents equal dates/sizes from being reshuffled by
    // Swift's non-stable sort whenever unrelated view state changes.
    let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
    if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
    return lhs.id < rhs.id
  }
}

/// Optional hints from OpenList's existing refresh response; WebDAV remains authoritative.
enum OpenListArtworkHints {
  static func parse(_ data: Data) -> [String: URL] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (json["code"] as? NSNumber)?.intValue == 200,
      let payload = json["data"] as? [String: Any],
      let entries = payload["content"] as? [[String: Any]] else { return [:] }
    var result: [String: URL] = [:]
    for entry in entries {
      guard entry["is_dir"] as? Bool != true,
        let name = entry["name"] as? String, !name.isEmpty,
        let raw = entry["thumb"] as? String,
        let url = URL(string: raw),
        let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
        url.host != nil, url.user == nil, url.password == nil else { continue }
      result[name] = url
    }
    return result
  }
}

/// Discrete resting densities with a dead zone for accidental two-finger movement.
enum MediaGridZoomPolicy {
  static let levels = [1, 2, 3, 4, 6]

  static func liveScale(_ magnification: Double) -> Double {
    guard magnification.isFinite, magnification > 0 else { return 1 }
    if magnification < 0.65 { return 0.65 - 0.15 * (1 - exp(-(0.65 - magnification) * 4)) }
    if magnification > 1.65 { return 1.65 + 0.2 * (1 - exp(-(magnification - 1.65) * 3)) }
    return magnification
  }

  static func handoffScale(_ scale: Double, from oldColumns: Int, to newColumns: Int) -> Double {
    scale * Double(normalized(newColumns)) / Double(normalized(oldColumns))
  }

  static func normalized(_ columns: Int) -> Int {
    levels.min(by: { abs($0 - min(max(columns, 1), 6)) < abs($1 - min(max(columns, 1), 6)) }) ?? 3
  }

  static func targetColumns(from columns: Int, magnification: Double) -> Int {
    let current = normalized(columns)
    guard magnification.isFinite, magnification > 0,
      magnification < 0.94 || magnification > 1.06 else { return current }
    let target = Double(current) / min(max(magnification, 0.1), 10)
    let nearest = levels.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) ?? current
    if nearest != current { return nearest }
    let index = levels.firstIndex(of: current) ?? 2
    return levels[min(max(index + (magnification > 1 ? -1 : 1), 0), levels.count - 1)]
  }
}

/// Conservative WebDAV relocation matching; paths and expiring cover URLs are
/// deliberately excluded. An ETag is a version hint, not assumed to be a SHA-1.
enum FavoriteRelocationPolicy {
  static func key(_ item: CloudItem) -> String? {
    guard item.id.hasPrefix("/"), !item.isDirectory, item.size > 0 else { return nil }
    let version = item.sha1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !version.isEmpty else { return nil }
    let fields = [item.name.precomposedStringWithCanonicalMapping,
                  String(item.size), version, String(item.modifiedAt.timeIntervalSince1970)]
    return fields.map { "\($0.utf8.count):\($0)" }.joined()
  }

  static func reconciled(_ favorites: [CloudItem], with items: [CloudItem]) -> [CloudItem] {
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let byKey = Dictionary(grouping: Array(byID.values).filter { key($0) != nil }, by: { key($0)! })
    var seen = Set<String>()
    return favorites.compactMap { saved in
      let resolved: CloudItem
      if let current = byID[saved.id] { resolved = current }
      else if let fingerprint = key(saved), let matches = byKey[fingerprint], matches.count == 1 {
        resolved = matches[0]
      } else { resolved = saved }
      return seen.insert(resolved.id).inserted ? resolved : nil
    }
  }
}

/// Progress is proportional to cell width, in both pinch directions.
enum PhotoGridTransitionPolicy {
  static func projectedProgress(progress: Double, velocity: Double, targetRatio: Double) -> Double {
    guard progress.isFinite, velocity.isFinite, targetRatio.isFinite,
      abs(targetRatio - 1) > 0.0001 else { return 0 }
    // A short, capped projection avoids requiring a slow pinch to reach halfway.
    let projected = progress + min(max(velocity * 0.10 / (targetRatio - 1), -0.2), 0.2)
    return min(max(projected, 0), 1)
  }

  static func progress(magnification: Double, targetRatio: Double) -> Double {
    guard magnification.isFinite, targetRatio.isFinite, magnification > 0,
      targetRatio > 0, abs(targetRatio - 1) > 0.0001 else { return 0 }
    return min(max((magnification - 1) / (targetRatio - 1), 0), 1)
  }
}

/// One scalar spans every resting density. No UIKit transition completion owns state.
struct PhotoGridZoomState {
  enum Phase: String { case idle, tracking, settling, cancelled }
  var phase: Phase = .idle
  var position: Double = 2
  var velocity: Double = 0
  var target: Double = 2
  var generation = 0
  private var startWidth: Double = 1

  mutating func begin(widths: [Double]) {
    generation &+= 1
    phase = .tracking
    startWidth = Self.width(at: position, widths: widths)
    velocity = 0
  }
  mutating func track(scale: Double, speed: Double, widths: [Double]) {
    guard phase == .tracking, scale.isFinite, scale > 0 else { return }
    position = Self.position(for: startWidth * scale, widths: widths)
    let index = min(Int(position), widths.count - 2)
    velocity = speed.isFinite ? min(max(startWidth * speed / (widths[index + 1] - widths[index]), -12), 12) : 0
  }
  mutating func end(cancelled: Bool = false) {
    phase = cancelled ? .cancelled : .settling
    if cancelled { velocity = 0 }
    target = min(max((position + velocity * 0.12).rounded(), 0), 4)
  }
  mutating func step(seconds: Double, reduceMotion: Bool) -> Bool {
    guard phase == .settling || phase == .cancelled else { return false }
    let omega = reduceMotion ? 32.0 : 22.0
    // Exact critically damped solution: stable at both 60 Hz and 120 Hz.
    let dt = min(max(seconds, 0), 0.05)
    let delta = position - target
    let c = velocity + omega * delta
    let decay = exp(-omega * dt)
    position = min(max(target + (delta + c * dt) * decay, 0), 4)
    velocity = (velocity - omega * c * dt) * decay
    if abs(position - target) < 0.001 && abs(velocity) < 0.01 {
      position = target; velocity = 0; phase = .idle
      return true
    }
    return false
  }
  static func width(at position: Double, widths: [Double]) -> Double {
    let p = min(max(position, 0), Double(widths.count - 1))
    let i = min(Int(p), widths.count - 2)
    return widths[i] + (widths[i + 1] - widths[i]) * (p - Double(i))
  }
  static func position(for width: Double, widths: [Double]) -> Double {
    for i in 0..<(widths.count - 1) where width >= widths[i + 1] {
      return Double(i) + min(max((widths[i] - width) / (widths[i] - widths[i + 1]), 0), 1)
    }
    return Double(widths.count - 1)
  }
}

/// Pure geometry used by the shipping layout and exhaustive coverage tests.
/// Interpolated row Y is monotonic in media index even when columns wrap.
struct PhotoGridGeometry {
  var width: Double
  var position: Double
  var compact: Bool
  var top: Double
  var captionHeight: Double
  var count: Int
  var gap: Double { compact ? 2 : 9 }
  var rowGap: Double { compact ? 2 : 11 }
  var inset: Double { compact ? 2 : 10 }
  var widths: [Double] {
    MediaGridZoomPolicy.levels.map { max(1, (width - inset * 2 - Double($0 - 1) * gap) / Double($0)) }
  }
  var pair: (Int, Int, Double) {
    let p = min(max(position, 0), 4)
    let lower = min(Int(p), 3)
    return (MediaGridZoomPolicy.levels[lower], MediaGridZoomPolicy.levels[lower + 1], p - Double(lower))
  }
  private func frame(_ index: Int, columns: Int) -> CGRect {
    let w = max(1, (width - inset * 2 - Double(columns - 1) * gap) / Double(columns))
    let h = compact ? w : w * 9 / 16 + captionHeight
    return CGRect(x: inset + Double(index % columns) * (w + gap),
                  y: top + Double(index / columns) * (h + rowGap), width: w, height: h)
  }
  func frame(_ index: Int) -> CGRect {
    let (a, b, t) = pair
    let x = frame(index, columns: a), y = frame(index, columns: b)
    return CGRect(x: x.minX + (y.minX - x.minX) * t, y: x.minY + (y.minY - x.minY) * t,
                  width: x.width + (y.width - x.width) * t, height: x.height + (y.height - x.height) * t)
  }
  var bottom: Double { count == 0 ? top : Double(frame(count - 1).maxY) + rowGap }
  func candidates(in rect: CGRect) -> Range<Int> {
    // Search the CURRENT interpolated geometry, not endpoint viewport unions.
    func lowerBound(_ predicate: (Int) -> Bool) -> Int {
      var low = 0, high = count
      while low < high {
        let mid = (low + high) / 2
        if predicate(mid) { high = mid } else { low = mid + 1 }
      }
      return low
    }
    let first = lowerBound { frame($0).maxY >= rect.minY }
    let last = lowerBound { frame($0).minY > rect.maxY }
    return first..<max(first, last)
  }
}
