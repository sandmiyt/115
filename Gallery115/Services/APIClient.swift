import Foundation

/// Stable compatibility facade. Cineva 2.0 treats OpenList/AList WebDAV as the
/// mounted media source; iPhone no longer calls 115 Open API while browsing or playing.
actor APIClient {
  static let userAgent = WebDAVProvider.userAgent

  private let provider = WebDAVProvider.shared

  func validateCredentials() async throws {
    try await provider.validateCredentials()
  }

  func validate(configuration: WebDAVMountConfiguration) async throws {
    try await provider.validate(configuration: configuration)
  }

  func listFolder(id: String) async throws -> [CloudItem] {
    try await provider.listFolder(id: id)
  }

  func listFolderPage(
    id: String,
    offset: Int,
    limit: Int = 56,
    forceRefresh: Bool = false,
    sortOrder: CloudItemSortOrder = .updated
  ) async throws -> CloudFolderPage {
    try await provider.listFolderPage(
      id: id,
      offset: offset,
      limit: limit,
      forceRefresh: forceRefresh,
      sortOrder: sortOrder
    )
  }

  func videoSources(for item: CloudItem) async throws -> [VideoSource] {
    try await provider.videoSources(for: item)
  }

  func localMetadata(for item: CloudItem) async -> LocalMediaMetadata? {
    await provider.localMetadata(for: item)
  }

  func externalSubtitles(for item: CloudItem) async -> [ExternalSubtitleTrack] {
    await provider.externalSubtitles(for: item)
  }

  func subtitleData(for track: ExternalSubtitleTrack) async throws -> Data {
    try await provider.subtitleData(for: track)
  }

  func externalSubtitleTracks(for item: CloudItem) async throws -> [ExternalSubtitleTrack] {
    try await provider.externalSubtitleTracks(for: item)
  }

  func subtitleCues(for track: ExternalSubtitleTrack) async throws -> [SubtitleCue] {
    try await provider.subtitleCues(for: track)
  }

  func sidecarChapters(for item: CloudItem) async -> [PlayerChapter] {
    await provider.sidecarChapters(for: item)
  }

  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async {
    await provider.updateVideoHistory(
      pickCode: pickCode,
      seconds: seconds,
      watchEnd: watchEnd
    )
  }

  func clearMountCache() async {
    await provider.clearMountCache()
  }
}
