import AVFoundation
import Foundation
import UIKit

actor ThumbnailService {
  private let fileManager = FileManager.default
  private let directory: URL

  init() {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    directory = base.appending(path: "GeneratedThumbnails", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func generatedThumbnail(for item: CloudItem, api: APIClient) async -> UIImage? {
    guard item.isVideo else { return nil }
    let key = item.sha1.isEmpty ? item.id : item.sha1
    let fileURL = directory.appending(path: "\(key).jpg")
    if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
      return image
    }

    guard let sources = try? await api.videoSources(for: item),
      let source = sources.first(where: { $0.isOriginal })
    else {
      return nil
    }

    let asset = AVURLAsset(
      url: source.url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
    )
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 540)

    let second = item.duration > 0 ? min(8, max(1, item.duration * 0.15)) : 5
    let time = CMTime(seconds: second, preferredTimescale: 600)

    guard let result = try? await generator.image(at: time) else { return nil }
    let image = UIImage(cgImage: result.image)
    if let data = image.jpegData(compressionQuality: 0.78) {
      try? data.write(to: fileURL, options: .atomic)
    }
    return image
  }

  func clearCache() {
    try? fileManager.removeItem(at: directory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    URLCache.shared.removeAllCachedResponses()
  }

}
