import Foundation

/// Routes the existing library and player calls to the selected media source.
/// Player code remains unaware of whether an item came from WebDAV or 115 Open API.
actor APIClient {
  static let userAgent = WebDAVProvider.userAgent

  private let webDAV = WebDAVProvider.shared
  private let cloud115 = Cloud115Provider.shared

  private var source: MediaSourceKind {
    MediaSourceSelectionStore.shared.resolvedSource
  }

  func validateCredentials() async throws {
    switch source {
    case .webDAV: try await webDAV.validateCredentials()
    case .cloud115: try await cloud115.validateCredentials()
    }
  }

  func validate(configuration: WebDAVMountConfiguration) async throws {
    try await webDAV.validate(configuration: configuration)
  }

  func validateCloud115Credentials() async throws {
    try await cloud115.validateCredentials()
  }

  func listFolder(id: String) async throws -> [CloudItem] {
    switch source {
    case .webDAV: return try await webDAV.listFolder(id: id)
    case .cloud115: return try await cloud115.listFolder(id: id)
    }
  }

  func listFolderPage(
    id: String,
    offset: Int,
    limit: Int = 56,
    forceRefresh: Bool = false,
    sortOrder: CloudItemSortOrder = .updated
  ) async throws -> CloudFolderPage {
    switch source {
    case .webDAV:
      return try await webDAV.listFolderPage(
        id: id, offset: offset, limit: limit,
        forceRefresh: forceRefresh, sortOrder: sortOrder
      )
    case .cloud115:
      return try await cloud115.listFolderPage(
        id: id, offset: offset, limit: limit,
        forceRefresh: forceRefresh, sortOrder: sortOrder
      )
    }
  }

  func videoSources(for item: CloudItem) async throws -> [VideoSource] {
    switch source {
    case .webDAV: return try await webDAV.videoSources(for: item)
    case .cloud115: return try await cloud115.videoSources(for: item)
    }
  }

  func initialVideoSources(for item: CloudItem, preferOriginal: Bool) async throws -> (sources: [VideoSource], hasDeferredSources: Bool) {
    if source == .cloud115 {
      do {
        if preferOriginal {
          return ([try await cloud115.playbackOriginalSource(for: item)], true)
        }
        let transcodes = try await cloud115.playbackTranscodedSources(for: item)
        if !transcodes.isEmpty { return (transcodes, true) }
      } catch let error as CloudProviderError {
        switch error {
        case .authenticationRequired, .rateLimited: throw error
        default: break
        }
      } catch {
        try Task.checkCancellation()
      }
      try Task.checkCancellation()
      // A failed preferred lookup falls back once. An already usable 1080p
      // stream must not wait for the unrelated original-file URL request.
      if preferOriginal {
        return (try await cloud115.playbackTranscodedSources(for: item), false)
      }
      return ([try await cloud115.playbackOriginalSource(for: item)], false)
    }
    try Task.checkCancellation()
    return (try await videoSources(for: item), false)
  }

  func remainingVideoSources(for item: CloudItem, preferOriginal: Bool) async throws -> [VideoSource] {
    guard source == .cloud115 else { return [] }
    if preferOriginal { return try await cloud115.playbackTranscodedSources(for: item) }
    return [try await cloud115.playbackOriginalSource(for: item)]
  }

  func thumbnailLibraryPage(id: String, offset: Int, forceRefresh: Bool = false) async throws -> ThumbnailLibraryPage {
    let page = try await listFolderPage(id: id, offset: offset, forceRefresh: forceRefresh)
    return ThumbnailLibraryPage(items: page.items, nextOffset: page.hasMore ? page.offset + page.limit : nil)
  }

  func localMetadata(for item: CloudItem) async -> LocalMediaMetadata? {
    switch source {
    case .webDAV: return await webDAV.localMetadata(for: item)
    case .cloud115: return await cloud115.localMetadata(for: item)
    }
  }

  func thumbnailSource(for item: CloudItem) async throws -> VideoSource? {
    switch source {
    case .webDAV: return try await webDAV.videoSources(for: item).first
    case .cloud115: return try await cloud115.thumbnailSource(for: item)
    }
  }

  func photoSource(for item: CloudItem) async throws -> VideoSource? {
    guard item.isPhoto else { return nil }
    switch source {
    case .webDAV: return try await webDAV.videoSources(for: item).first
    case .cloud115: return try await cloud115.photoSource(for: item)
    }
  }

  func cancelBackgroundArtwork() async {
    await webDAV.cancelArtworkDiscovery()
  }

  func serverThumbnailURL(for item: CloudItem) async -> URL? {
    guard source == .webDAV else { return nil }
    return await webDAV.serverThumbnailURL(for: item)
  }

  func posterData(for item: CloudItem) async -> Data? {
    guard source == .webDAV else { return nil }
    return await webDAV.posterData(for: item)
  }

  func externalSubtitles(for item: CloudItem) async -> [ExternalSubtitleTrack] {
    guard source == .webDAV else { return [] }
    return await webDAV.externalSubtitles(for: item)
  }

  func subtitleData(for track: ExternalSubtitleTrack) async throws -> Data {
    guard source == .webDAV else { throw CloudProviderError.invalidResponse("外部字幕") }
    return try await webDAV.subtitleData(for: track)
  }

  func externalSubtitleTracks(for item: CloudItem) async throws -> [ExternalSubtitleTrack] {
    guard source == .webDAV else { return [] }
    return try await webDAV.externalSubtitleTracks(for: item)
  }

  func subtitleCues(for track: ExternalSubtitleTrack) async throws -> [SubtitleCue] {
    guard source == .webDAV else { return [] }
    return try await webDAV.subtitleCues(for: track)
  }

  func sidecarChapters(for item: CloudItem) async -> [PlayerChapter] {
    guard source == .webDAV else { return [] }
    return await webDAV.sidecarChapters(for: item)
  }

  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async {
    switch source {
    case .webDAV:
      await webDAV.updateVideoHistory(pickCode: pickCode, seconds: seconds, watchEnd: watchEnd)
    case .cloud115:
      await cloud115.updateVideoHistory(pickCode: pickCode, seconds: seconds, watchEnd: watchEnd)
    }
  }

  func clearMountCache() async {
    switch source {
    case .webDAV: await webDAV.clearMountCache()
    case .cloud115: await cloud115.clearMountCache()
    }
  }

  func clearAllMountCaches() async {
    await webDAV.clearMountCache()
    await cloud115.clearMountCache()
  }
}
