import CryptoKit
import Foundation

/// A stable identity excludes rotating thumbnail URLs and WebDAV ETags.
struct ArtworkIdentity: Sendable {
  let namespace: String
  let itemID: String
  let size: Int64
  let modifiedAt: Date
  let legacyKey: String

  var key: String {
    let fields = ["artwork-v2", namespace, itemID, String(size),
                  String(modifiedAt.timeIntervalSince1970.rounded(.down))]
    return Self.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
  }

  static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func legacyHash(_ value: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return String(hash, radix: 16)
  }
}

/// Actor-owned durable artwork. No age expiry or automatic disk eviction.
/// Paths are injectable so cold-launch tests never touch the user's real data.
struct ArtworkDiskStore: Sendable {
  let directory: URL
  let legacyDirectory: URL

  init(directory: URL? = nil, legacyDirectory: URL? = nil) {
    let files = FileManager.default
    self.directory = directory ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CinevaArtwork", isDirectory: true)
    self.legacyDirectory = legacyDirectory ?? files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("GeneratedThumbnails", isDirectory: true)
  }

  func fileURL(for identity: ArtworkIdentity) -> URL {
    directory.appendingPathComponent(identity.key + ".jpg")
  }

  func read(_ identity: ArtworkIdentity) throws -> Data? {
    let destination = fileURL(for: identity)
    if FileManager.default.fileExists(atPath: destination.path) {
      return try Data(contentsOf: destination)
    }
    try migrateLegacyDirectory(namespace: identity.namespace)
    let owner = try? String(contentsOf: legacyOwnerURL, encoding: .utf8)
    guard owner == ArtworkIdentity.digest(identity.namespace) else { return nil }
    // Old versions had no mount/account identity. Claim this fallback once for
    // the first connected mount, never reuse it for another server/account.
    for oldKey in Set([identity.legacyKey, identity.itemID]) {
      let oldURL = migratedLegacyDirectory.appendingPathComponent(ArtworkIdentity.legacyHash(oldKey) + ".jpg")
      guard FileManager.default.fileExists(atPath: oldURL.path) else { continue }
      let data = try Data(contentsOf: oldURL)
      try write(data, for: identity)
      try? FileManager.default.removeItem(at: oldURL)
      return data
    }
    return nil
  }

  func write(_ data: Data, for identity: ArtworkIdentity) throws {
    try prepareDirectory()
    try data.write(to: fileURL(for: identity), options: .atomic)
  }

  func remove(_ identity: ArtworkIdentity) {
    try? FileManager.default.removeItem(at: fileURL(for: identity))
  }

  func usageBytes() -> Int64 {
    [directory, legacyDirectory].reduce(Int64(0)) { total, root in
      guard let files = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      ) else { return total }
      var bytes = total
      for case let url as URL in files where url.pathExtension == "jpg" {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
      }
      return bytes
    }
  }

  func clear() throws {
    // Dedicated artwork folders only, never the sandbox or library root.
    for root in [directory, legacyDirectory] where FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
    try prepareDirectory()
  }

  private var migratedLegacyDirectory: URL { directory.appendingPathComponent("Legacy", isDirectory: true) }
  private var legacyOwnerURL: URL { directory.appendingPathComponent(".legacy-owner") }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var root = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try root.setResourceValues(values)
  }

  private func migrateLegacyDirectory(namespace: String) throws {
    guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return }
    try prepareDirectory()
    if !FileManager.default.fileExists(atPath: legacyOwnerURL.path) {
      try Data(ArtworkIdentity.digest(namespace).utf8).write(to: legacyOwnerURL, options: .atomic)
    }
    guard !FileManager.default.fileExists(atPath: migratedLegacyDirectory.path) else { return }
    try FileManager.default.moveItem(at: legacyDirectory, to: migratedLegacyDirectory)
  }
}
