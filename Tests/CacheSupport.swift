#if CACHE_VALIDATION
import Foundation

// Test-only boundaries. No account/network access is permitted in cache tests.
actor APIClient {
  var thumbnailPages: [String: [ThumbnailLibraryPage]] = [:]
  private var thumbnailSourceValues: [VideoSource] = []
  private var thumbnailFallbackValue: VideoSource?
  private var thumbnailSourceError: Error?
  private var thumbnailSourceDelay = 0.0
  private var thumbnailFallbackError: Error?
  private(set) var thumbnailSourcesCalls = 0
  private(set) var thumbnailFallbackSourceCalls = 0
  private(set) var thumbnailFallbackAttempts: [[VideoSource]] = []
  func setThumbnailSources(_ sources: [VideoSource]) { thumbnailSourceValues = sources }
  func setThumbnailFallbackSource(_ source: VideoSource?) { thumbnailFallbackValue = source }
  func setThumbnailSourceError(_ error: Error?) { thumbnailSourceError = error }
  func setThumbnailSourceDelay(_ seconds: Double) { thumbnailSourceDelay = seconds }
  func setThumbnailFallbackError(_ error: Error?) { thumbnailFallbackError = error }
  func setThumbnailPages(_ pages: [String: [ThumbnailLibraryPage]]) { thumbnailPages = pages }
  func thumbnailLibraryPage(id: String, offset: Int, forceRefresh: Bool = false) async throws -> ThumbnailLibraryPage {
    guard let pages = thumbnailPages[id], pages.indices.contains(offset) else {
      return ThumbnailLibraryPage(items: [], nextOffset: nil)
    }
    return pages[offset]
  }
  func thumbnailSource(for item: CloudItem) async throws -> VideoSource? {
    try await thumbnailSources(for: item).first
  }
  func thumbnailSources(for item: CloudItem) async throws -> [VideoSource] {
    try Task.checkCancellation()
    thumbnailSourcesCalls += 1
    if thumbnailSourceDelay > 0 { try await Task.sleep(for: .seconds(thumbnailSourceDelay)) }
    try Task.checkCancellation()
    if let thumbnailSourceError { throw thumbnailSourceError }
    return thumbnailSourceValues
  }
  func thumbnailFallbackSource(for item: CloudItem, attempted: [VideoSource]) async throws -> VideoSource? {
    try Task.checkCancellation()
    thumbnailFallbackSourceCalls += 1
    thumbnailFallbackAttempts.append(attempted)
    guard !attempted.contains(where: \.isOriginal) else { return nil }
    if let thumbnailFallbackError { throw thumbnailFallbackError }
    return thumbnailFallbackValue
  }
  func photoSource(for item: CloudItem) async throws -> VideoSource? { nil }
  func serverThumbnailURL(for item: CloudItem) async -> URL? { nil }
  func posterData(for item: CloudItem) async -> Data? { nil }
  func localMetadata(for item: CloudItem) async -> TestMetadata? { nil }
  func videoSources(for item: CloudItem) async throws -> [VideoSource] { [] }
}

enum CloudProviderError: Error {
  case authenticationRequired(String), rateLimited(String), network(String)
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
