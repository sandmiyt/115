import AVFoundation
import Foundation
import ImageIO
import UIKit

/// Generates missing video artwork through the mounted WebDAV stream, never through
/// 115 Open playback APIs. Generation is strictly serialized and cached on disk so
/// scrolling a large library cannot create a burst of remote video requests.
actor ThumbnailService {
  private let fileManager = FileManager.default
  private let directory: URL
  private let memoryCache = NSCache<NSString, UIImage>()
  private var generatorBusy = false
  private var generatorWaiters: [CheckedContinuation<Void, Never>] = []
  private let maximumCacheBytes: Int64 = 1_073_741_824
  private var lastCacheTrimAt = Date.distantPast

  init() {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    directory = base.appending(path: "GeneratedThumbnails", directoryHint: .isDirectory)
    memoryCache.countLimit = 160
    memoryCache.totalCostLimit = 72 * 1_024 * 1_024
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func generatedThumbnail(for item: CloudItem, api: APIClient) async -> UIImage? {
    guard item.isVideo else { return nil }
    let cacheKey = thumbnailCacheKey(for: item)
    if let cached = memoryCache.object(forKey: cacheKey as NSString) {
      return cached
    }
    let fileURL = cachedFileURL(for: item)
    if let cached = loadImage(at: fileURL) {
      cacheInMemory(cached, key: cacheKey)
      touch(fileURL)
      return cached
    }
    guard !Task.isCancelled else { return nil }

    if let metadata = await api.localMetadata(for: item),
      let posterData = metadata.posterData,
      let poster = downsampledImage(from: posterData, maximumPixelSize: 960)
    {
      guard !Task.isCancelled else { return nil }
      storeGeneratedThumbnail(poster, for: item)
      return poster
    }

    // Disc images are handled by the VLC/original-disc path. Asking AVFoundation
    // to probe a remote ISO/IMG just to synthesize a thumbnail can trigger large
    // random reads and offers no useful fallback. Local poster artwork above still works.
    if item.isDiscImage { return nil }

    guard !Task.isCancelled else { return nil }
    await acquireGenerator()
    defer { releaseGenerator() }

    if let cached = loadImage(at: fileURL) {
      cacheInMemory(cached, key: cacheKey)
      touch(fileURL)
      return cached
    }
    guard !Task.isCancelled else { return nil }

    guard let source = try? await api.videoSources(for: item).first else { return nil }
    let asset: AVURLAsset
    if source.headers.isEmpty {
      asset = AVURLAsset(url: source.url)
    } else {
      asset = AVURLAsset(
        url: source.url,
        options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
      )
    }

    guard !Task.isCancelled else { return nil }
    guard (try? await asset.load(.isPlayable)) == true else { return nil }
    let loadedDuration = try? await asset.load(.duration)
    let duration = loadedDuration?.seconds ?? 0
    let targetSeconds: Double
    if duration.isFinite, duration > 2 {
      targetSeconds = min(max(duration * 0.12, 1.0), 8.0)
    } else {
      targetSeconds = 1.0
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 540)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

    guard let cgImage = try? generator.copyCGImage(
      at: CMTime(seconds: targetSeconds, preferredTimescale: 600),
      actualTime: nil
    ) else {
      return nil
    }

    guard !Task.isCancelled else { return nil }
    let image = UIImage(cgImage: cgImage)
    storeGeneratedThumbnail(image, for: item)
    return image
  }

  func storeGeneratedThumbnail(_ image: UIImage, for item: CloudItem) {
    cacheInMemory(image, key: thumbnailCacheKey(for: item))
    guard let data = image.jpegData(compressionQuality: 0.80) else { return }
    let url = cachedFileURL(for: item)
    try? data.write(to: url, options: .atomic)
    touch(url)
    trimCacheIfNeeded()
  }

  func cacheUsageBytes() -> Int64 {
    guard let files = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return 0 }
    return files.reduce(0) { partial, url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return partial + Int64(size)
    }
  }

  func clearCache() {
    memoryCache.removeAllObjects()
    try? fileManager.removeItem(at: directory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    URLCache.shared.removeAllCachedResponses()
  }

  private func cachedFileURL(for item: CloudItem) -> URL {
    directory.appending(path: "\(stableHash(thumbnailCacheKey(for: item))).jpg")
  }

  private func thumbnailCacheKey(for item: CloudItem) -> String {
    item.sha1.isEmpty ? item.id : item.sha1
  }

  private func loadImage(at url: URL) -> UIImage? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return downsampledImage(from: data, maximumPixelSize: 960)
  }

  private func cacheInMemory(_ image: UIImage, key: String) {
    let pixelWidth = max(Int(image.size.width * image.scale), 1)
    let pixelHeight = max(Int(image.size.height * image.scale), 1)
    let cost = min(pixelWidth * pixelHeight * 4, 16 * 1_024 * 1_024)
    memoryCache.setObject(image, forKey: key as NSString, cost: cost)
  }

  private func downsampledImage(from data: Data, maximumPixelSize: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: image)
  }

  private func acquireGenerator() async {
    if !generatorBusy {
      generatorBusy = true
      return
    }
    await withCheckedContinuation { continuation in
      generatorWaiters.append(continuation)
    }
  }

  private func releaseGenerator() {
    if generatorWaiters.isEmpty {
      generatorBusy = false
    } else {
      let next = generatorWaiters.removeFirst()
      next.resume()
    }
  }

  private func touch(_ url: URL) {
    try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
  }

  private func trimCacheIfNeeded() {
    // Directory enumeration gets increasingly expensive in large libraries.
    // At most one trim pass per minute keeps insertion latency predictable while
    // still enforcing the disk budget during sustained thumbnail generation.
    let now = Date()
    guard now.timeIntervalSince(lastCacheTrimAt) >= 60 else { return }
    lastCacheTrimAt = now
    guard let files = try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    var entries: [(url: URL, size: Int64, date: Date)] = files.map { url in
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      return (
        url,
        Int64(values?.fileSize ?? 0),
        values?.contentModificationDate ?? .distantPast
      )
    }
    var total = entries.reduce(Int64(0)) { $0 + $1.size }
    guard total > maximumCacheBytes else { return }

    entries.sort { $0.date < $1.date }
    let target = Int64(Double(maximumCacheBytes) * 0.82)
    for entry in entries where total > target {
      try? fileManager.removeItem(at: entry.url)
      total -= entry.size
    }
  }

  private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return String(hash, radix: 16)
  }
}
