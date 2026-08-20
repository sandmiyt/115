import Foundation

struct CloudItem: Codable, Hashable, Identifiable {
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

  var isDiscImage: Bool {
    ["iso", "img"].contains(fileExtension.lowercased())
  }

  var prefersVLCForOriginal: Bool {
    let ext = fileExtension.lowercased()
    return ["mkv", "avi", "flv", "rmvb", "wmv", "m2ts", "mts", "ts", "webm", "iso", "img"].contains(ext)
  }
}
