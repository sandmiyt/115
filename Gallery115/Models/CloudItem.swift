import Foundation

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

  static func normalized(_ columns: Int) -> Int {
    levels.min(by: { abs($0 - min(max(columns, 1), 6)) < abs($1 - min(max(columns, 1), 6)) }) ?? 3
  }

  static func targetColumns(from columns: Int, magnification: Double) -> Int {
    let current = normalized(columns)
    guard magnification.isFinite, magnification > 0,
      magnification < 0.88 || magnification > 1.12 else { return current }
    let target = Double(current) / min(max(magnification, 0.1), 10)
    let nearest = levels.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) ?? current
    if nearest != current { return nearest }
    let index = levels.firstIndex(of: current) ?? 2
    return levels[min(max(index + (magnification > 1 ? -1 : 1), 0), levels.count - 1)]
  }
}
