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
