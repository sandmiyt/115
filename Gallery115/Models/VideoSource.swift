import Foundation

struct VideoSource: Identifiable, Hashable {
  enum Kind: Hashable {
    case transcoded
    case original
  }

  let id: String
  let title: String
  let definition: Int
  let url: URL
  let kind: Kind
  let headers: [String: String]

  var isOriginal: Bool { kind == .original }

  // 115's existing definition mapping uses 4 for its 1080P transcode.
  // A source description may supply the resolution when definition is absent.
  var is1080p: Bool {
    !isOriginal && (definition == 4 || (definition <= 0 && title.uppercased().contains("1080P")))
  }

  static func preferred1080p(in sources: [VideoSource]) -> VideoSource? {
    let transcodes = sources.filter { !$0.isOriginal }
    if let fullHD = transcodes.first(where: \.is1080p) { return fullHD }
    // Prefer a lower transcode over switching back to a heavy original/4K file.
    if let lower = transcodes.filter({ (1...3).contains($0.definition) })
      .max(by: { $0.definition < $1.definition }) { return lower }
    return transcodes.min(by: { $0.definition < $1.definition })
      ?? sources.first(where: \.isOriginal)
  }
}
