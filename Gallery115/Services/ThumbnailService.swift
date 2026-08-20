import AVFoundation
import Foundation
import UIKit

/// Generates missing video artwork through the mounted WebDAV stream, never through
/// 115 Open playback APIs. Generation is strictly serialized and cached on disk so
/// scrolling a large library cannot create a burst of remote video requests.
actor ThumbnailService {
  private let fileManager = FileManager.default
  private let directory: URL
  private var generatorBusy = false
  private var generatorWaiters: [CheckedContinuation<Void, Never>] = []

  init() {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    directory = base.appending(path: "GeneratedThumbnails", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func generatedThumbnail(for item: CloudItem, api: APIClient) async -> UIImage? {
    guard item.isVideo else { return nil }
    let fileURL = cachedFileURL(for: item)
    if let cached = loadImage(at: fileURL) { return cached }

    await acquireGenerator()
    defer { releaseGenerator() }

    if let cached = loadImage(at: fileURL) { return cached }

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

    let image = UIImage(cgImage: cgImage)
    storeGeneratedThumbnail(image, for: item)
    return image
  }

  func storeGeneratedThumbnail(_ image: UIImage, for item: CloudItem) {
    guard let data = image.jpegData(compressionQuality: 0.80) else { return }
    try? data.write(to: cachedFileURL(for: item), options: .atomic)
  }

  func clearCache() {
    try? fileManager.removeItem(at: directory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    URLCache.shared.removeAllCachedResponses()
  }

  private func cachedFileURL(for item: CloudItem) -> URL {
    let key = item.sha1.isEmpty ? item.id : item.sha1
    return directory.appending(path: "\(stableHash(key)).jpg")
  }

  private func loadImage(at url: URL) -> UIImage? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
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

  private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return String(hash, radix: 16)
  }
}
