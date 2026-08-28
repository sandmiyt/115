#if CACHE_VALIDATION
import Foundation

// Test-only boundaries. No account/network access is permitted in cache tests.
actor APIClient {
  func localMetadata(for item: CloudItem) async -> TestMetadata? { nil }
  func videoSources(for item: CloudItem) async throws -> [VideoSource] { [] }
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
