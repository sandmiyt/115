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
}
