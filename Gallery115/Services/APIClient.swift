import Foundation

/// Compatibility facade retained so stable views/player code do not need a risky all-at-once rewrite.
/// All 115 networking/authentication now lives in Cloud115Provider + Cloud115AuthManager.
actor APIClient {
  static let userAgent = Cloud115Provider.userAgent

  private let provider = Cloud115Provider.shared

  func validateCredentials() async throws {
    try await provider.validateCredentials()
  }

  func listFolder(id: String) async throws -> [CloudItem] {
    try await provider.listFolder(id: id)
  }

  func videoSources(for item: CloudItem) async throws -> [VideoSource] {
    try await provider.videoSources(for: item)
  }

  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async {
    await provider.updateVideoHistory(
      pickCode: pickCode,
      seconds: seconds,
      watchEnd: watchEnd
    )
  }
}
