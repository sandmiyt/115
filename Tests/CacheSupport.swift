#if CACHE_VALIDATION
import Foundation

// Test-only boundaries. No account/network access is permitted in cache tests.
actor APIClient {
  var thumbnailPages: [String: [ThumbnailLibraryPage]] = [:]
  func setThumbnailPages(_ pages: [String: [ThumbnailLibraryPage]]) { thumbnailPages = pages }
  func thumbnailLibraryPage(id: String, offset: Int, forceRefresh: Bool = false) async throws -> ThumbnailLibraryPage {
    guard let pages = thumbnailPages[id], pages.indices.contains(offset) else {
      return ThumbnailLibraryPage(items: [], nextOffset: nil)
    }
    return pages[offset]
  }
  func thumbnailSource(for item: CloudItem) async throws -> VideoSource? { nil }
  func photoSource(for item: CloudItem) async throws -> VideoSource? { nil }
  func serverThumbnailURL(for item: CloudItem) async -> URL? { nil }
  func posterData(for item: CloudItem) async -> Data? { nil }
  func localMetadata(for item: CloudItem) async -> TestMetadata? { nil }
  func videoSources(for item: CloudItem) async throws -> [VideoSource] { [] }
}

enum MediaSourceKind { case webDAV, cloud115 }
struct MediaSourceSelectionStore {
  static let shared = MediaSourceSelectionStore()
  var resolvedSource: MediaSourceKind { .webDAV }
}

struct TestMetadata { let posterData: Data? }
struct TestMount {
  let normalizedWebDAVURL: URL?
  let serverURL: String
  let username: String
  let normalizedRootPath: String
}
struct WebDAVCredentialStore {
  static let shared = WebDAVCredentialStore()
  var configuration: TestMount? { nil }
}
#endif
