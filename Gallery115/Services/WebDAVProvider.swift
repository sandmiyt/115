import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

actor WebDAVProvider: CloudProvider {
  static let shared = WebDAVProvider()
  static let userAgent = "Cineva-iOS/2.2"

  private let store = WebDAVCredentialStore.shared
  private let session: URLSession
  private var memoryCache: [String: [CloudItem]] = [:]
  private var orderedItemCache: [String: [CloudItem]] = [:]
  private var rawDirectoryCache: [String: [CloudItem]] = [:]
  private var directoryFileIndexCache: [String: [String: CloudItem]] = [:]
  private var metadataCache: [String: LocalMediaMetadata] = [:]
  private var metadataMisses: Set<String> = []
  private var lastRequestAt: Date = .distantPast
  private let cacheDirectory: URL

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 120
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpMaximumConnectionsPerHost = 4
    session = URLSession(configuration: config)

    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    cacheDirectory = base.appending(path: "CinevaWebDAVMountCache", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(
      at: cacheDirectory,
      withIntermediateDirectories: true
    )
  }

  func validateCredentials() async throws {
    guard let configuration = store.configuration else {
      throw CloudProviderError.authenticationRequired("尚未连接 OpenList / AList 媒体源。")
    }
    try await validate(configuration: configuration)
  }

  func validate(configuration: WebDAVMountConfiguration) async throws {
    _ = try await performPROPFIND(
      configuration: configuration,
      logicalPath: configuration.normalizedRootPath,
      depth: "0"
    )
  }

  func listFolderPage(
    id: String,
    offset: Int,
    limit: Int,
    forceRefresh: Bool
  ) async throws -> CloudFolderPage {
    try await listFolderPage(
      id: id,
      offset: offset,
      limit: limit,
      forceRefresh: forceRefresh,
      sortOrder: .updated
    )
  }

  func listFolderPage(
    id: String,
    offset: Int,
    limit: Int,
    forceRefresh: Bool,
    sortOrder: CloudItemSortOrder
  ) async throws -> CloudFolderPage {
    guard let configuration = store.configuration else {
      throw CloudProviderError.authenticationRequired("尚未连接 OpenList / AList 媒体源。")
    }

    let path = normalizeLogicalPath(id.isEmpty ? configuration.normalizedRootPath : id)
    let cacheKey = configuration.cacheNamespace + "|" + path
    let safeLimit = max(1, min(limit, 200))
    var servedFromCache = false

    let allItems: [CloudItem]
    if !forceRefresh, let cached = memoryCache[cacheKey] {
      allItems = cached
      servedFromCache = true
    } else if !forceRefresh, let cached = readDiskCache(cacheKey: cacheKey) {
      memoryCache[cacheKey] = cached
      allItems = cached
      servedFromCache = true
    } else {
      do {
        if forceRefresh {
          // Cineva's local caches are only half of the story. OpenList/AList
          // itself caches mounted-storage directory listings (commonly for
          // tens of minutes). Best-effort refresh that server-side cache first
          // using the already saved OpenList account, then re-read through
          // WebDAV so newly added/removed cloud files become visible now.
          _ = await refreshOpenListDirectoryCache(
            configuration: configuration,
            logicalPath: path
          )
          rawDirectoryCache.removeValue(forKey: configuration.cacheNamespace + "|raw|" + path)
          directoryFileIndexCache.removeValue(forKey: configuration.cacheNamespace + "|raw|" + path)
          memoryCache.removeValue(forKey: cacheKey)
          orderedItemCache = orderedItemCache.filter { !$0.key.hasPrefix(cacheKey + "|sort|") }
          metadataCache.removeAll()
          metadataMisses.removeAll()
        }
        let fetched = try await fetchDirectory(
          configuration: configuration,
          logicalPath: path
        )
        memoryCache[cacheKey] = fetched
        writeDiskCache(fetched, cacheKey: cacheKey)
        allItems = fetched
      } catch {
        if let cached = memoryCache[cacheKey] ?? readDiskCache(cacheKey: cacheKey) {
          memoryCache[cacheKey] = cached
          allItems = cached
          servedFromCache = true
        } else {
          throw error
        }
      }
    }

    let orderedCacheKey = cacheKey + "|sort|" + sortOrder.rawValue
    let orderedItems: [CloudItem]
    if let cached = orderedItemCache[orderedCacheKey], cached.count == allItems.count {
      orderedItems = cached
    } else {
      orderedItems = CloudItemCollectionPolicy.ordered(allItems, by: sortOrder)
      orderedItemCache[orderedCacheKey] = orderedItems
    }

    let start = min(max(offset, 0), orderedItems.count)
    let end = min(start + safeLimit, orderedItems.count)
    let pageItems = Array(orderedItems[start..<end])

    return CloudFolderPage(
      items: pageItems,
      offset: start,
      limit: safeLimit,
      total: orderedItems.count,
      hasMore: end < orderedItems.count,
      servedFromCache: servedFromCache
    )
  }

  func videoSources(for item: CloudItem) async throws -> [VideoSource] {
    guard !item.isDirectory else { throw CloudProviderError.noPlayableSource }
    guard let configuration = store.configuration else {
      throw CloudProviderError.authenticationRequired("尚未连接 OpenList / AList 媒体源。")
    }

    let url = try webDAVURL(
      configuration: configuration,
      logicalPath: item.id,
      isDirectory: false
    )
    var headers = ["User-Agent": Self.userAgent]
    if let authorization = configuration.authorizationHeader {
      headers["Authorization"] = authorization
    }

    return [
      VideoSource(
        id: "webdav-original-\(item.id)",
        title: "原画",
        definition: 100,
        url: url,
        kind: .original,
        headers: headers
      )
    ]
  }

  func localMetadata(for item: CloudItem) async -> LocalMediaMetadata? {
    guard !Task.isCancelled else { return nil }
    guard !item.isDirectory, let configuration = store.configuration else { return nil }
    if let cached = metadataCache[item.id] { return cached }
    if metadataMisses.contains(item.id) { return nil }

    let parentPath = normalizeLogicalPath(item.parentID)
    let rawKey = configuration.cacheNamespace + "|raw|" + parentPath
    let entries: [CloudItem]
    if let cached = rawDirectoryCache[rawKey] {
      entries = cached
    } else {
      do {
        entries = try await fetchDirectoryEntries(
          configuration: configuration,
          logicalPath: parentPath
        )
      } catch {
        // Playback may cancel background artwork discovery. Cancellation does
        // not mean the file has no metadata and must not poison the miss cache.
        if !Task.isCancelled { metadataMisses.insert(item.id) }
        return nil
      }
    }

    guard !Task.isCancelled else { return nil }
    let stem = URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent.lowercased()
    // Some WebDAV backends are case-sensitive and may legally contain both
    // Poster.jpg and poster.jpg. Dictionary(uniqueKeysWithValues:) would trap
    // at runtime after lowercasing those names, so keep the first matching file
    // instead of allowing a duplicate-key crash while loading metadata.
    let byName: [String: CloudItem]
    if let cached = directoryFileIndexCache[rawKey] {
      byName = cached
    } else {
      var index: [String: CloudItem] = [:]
      index.reserveCapacity(entries.count)
      for file in entries where !file.isDirectory {
        let key = file.name.lowercased()
        if index[key] == nil {
          index[key] = file
        }
      }
      directoryFileIndexCache[rawKey] = index
      byName = index
    }

    let nfoCandidates = ["\(stem).nfo", "movie.nfo", "tvshow.nfo"]
    let posterCandidates = [
      "\(stem)-poster.jpg", "\(stem)-poster.jpeg", "\(stem)-poster.png",
      "poster.jpg", "poster.jpeg", "poster.png", "folder.jpg", "cover.jpg",
    ]
    var parsed = ParsedNFO()
    if let nfoItem = nfoCandidates.compactMap({ byName[$0] }).first {
      let data = try? await fetchResourceData(
        configuration: configuration,
        logicalPath: nfoItem.id,
        maximumBytes: 1_500_000
      )
      if let data { parsed = SimpleNFOParser.parse(data: data) }
    }

    guard !Task.isCancelled else { return nil }
    var posterData: Data?
    if let poster = posterCandidates.compactMap({ byName[$0] }).first {
      posterData = try? await fetchResourceData(
        configuration: configuration,
        logicalPath: poster.id,
        maximumBytes: 12_000_000
      )
    }

    // Fanart files are deliberately discovered but not eagerly downloaded here.
    // This method is also called by visible thumbnail cards; eagerly fetching a
    // multi-megabyte backdrop for every card would turn scrolling into background
    // network traffic. Poster/NFO are the only artwork needed by v2.2 surfaces.
    let fanartData: Data? = nil

    let metadata = LocalMediaMetadata(
      title: parsed.title,
      overview: parsed.plot,
      year: parsed.year,
      genre: parsed.genre,
      studio: parsed.studio,
      showTitle: parsed.showTitle,
      season: parsed.season,
      episode: parsed.episode,
      director: parsed.director,
      rating: parsed.rating,
      posterData: posterData,
      fanartData: fanartData
    )

    guard !Task.isCancelled else { return nil }
    guard metadata.hasUsefulMetadata else {
      metadataMisses.insert(item.id)
      return nil
    }
    metadataCache[item.id] = metadata
    return metadata
  }

  func externalSubtitles(for item: CloudItem) async -> [ExternalSubtitleTrack] {
    guard !item.isDirectory, let configuration = store.configuration else { return [] }
    let parentPath = normalizeLogicalPath(item.parentID)
    let entries: [CloudItem]
    do {
      entries = try await fetchDirectoryEntries(configuration: configuration, logicalPath: parentPath)
    } catch {
      return []
    }

    let stem = URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
    let normalizedStem = stem.lowercased()
    let supported: Set<String> = ["srt", "ass", "ssa", "vtt"]
    return entries.compactMap { candidate in
      guard !candidate.isDirectory, supported.contains(candidate.fileExtension.lowercased()) else { return nil }
      let candidateStem = URL(fileURLWithPath: candidate.name).deletingPathExtension().lastPathComponent
      let lower = candidateStem.lowercased()
      guard lower == normalizedStem || lower.hasPrefix(normalizedStem + ".") || lower.hasPrefix(normalizedStem + "-") || lower.hasPrefix(normalizedStem + "_") else { return nil }
      var suffix = String(candidateStem.dropFirst(min(candidateStem.count, stem.count)))
      suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
      let ext = candidate.fileExtension.uppercased()
      let title = suffix.isEmpty ? "外置字幕 · \(ext)" : "\(suffix) · \(ext)"
      return ExternalSubtitleTrack(id: candidate.id, title: title, logicalPath: candidate.id, fileExtension: candidate.fileExtension.lowercased())
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func subtitleData(for track: ExternalSubtitleTrack) async throws -> Data {
    guard let configuration = store.configuration else {
      throw CloudProviderError.authenticationRequired("尚未连接 OpenList / AList 媒体源。")
    }
    return try await fetchResourceData(configuration: configuration, logicalPath: track.logicalPath, maximumBytes: 8_000_000)
  }

  func externalSubtitleTracks(for item: CloudItem) async throws -> [ExternalSubtitleTrack] {
    await externalSubtitles(for: item)
  }

  func subtitleCues(for track: ExternalSubtitleTrack) async throws -> [SubtitleCue] {
    let data = try await subtitleData(for: track)
    return ExternalSubtitleParser.parse(data: data, fileExtension: track.fileExtension)
  }

  func sidecarChapters(for item: CloudItem) async -> [PlayerChapter] {
    guard !item.isDirectory, let configuration = store.configuration else { return [] }
    let parentPath = normalizeLogicalPath(item.parentID)
    let entries: [CloudItem]
    do { entries = try await fetchDirectoryEntries(configuration: configuration, logicalPath: parentPath) }
    catch { return [] }

    let stem = URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent.lowercased()
    let candidates = ["\(stem).chapters.txt", "chapters.txt"]
    guard let sidecar = entries.first(where: { candidate in
      !candidate.isDirectory && candidates.contains(candidate.name.lowercased())
    }), let data = try? await fetchResourceData(configuration: configuration, logicalPath: sidecar.id, maximumBytes: 512_000),
      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    else { return [] }

    var raw: [(start: Double, title: String)] = []
    for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
      let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, !value.hasPrefix("#") else { continue }
      let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
      guard let first = parts.first, let start = Self.parseChapterTimestamp(first) else { continue }
      let title = parts.count > 1 ? parts[1] : "章节 \(raw.count + 1)"
      raw.append((start, title))
    }
    raw.sort { $0.start < $1.start }
    return raw.enumerated().map { index, entry in
      let end = index + 1 < raw.count ? raw[index + 1].start : 0
      return PlayerChapter(id: "sidecar-\(index)-\(entry.start)", title: entry.title, start: entry.start, end: end)
    }
  }

  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async {
    // OpenList/AList WebDAV is intentionally read-only from Cineva.
    // Playback progress remains in Cineva's local LibraryStore.
  }

  func clearMountCache() async {
    memoryCache.removeAll()
    orderedItemCache.removeAll()
    rawDirectoryCache.removeAll()
    directoryFileIndexCache.removeAll()
    metadataCache.removeAll()
    metadataMisses.removeAll()
    try? FileManager.default.removeItem(at: cacheDirectory)
    try? FileManager.default.createDirectory(
      at: cacheDirectory,
      withIntermediateDirectories: true
    )
  }

  /// Best-effort invalidation of OpenList/AList's own storage listing cache.
  ///
  /// The WebDAV endpoint can legitimately return an old directory even after
  /// Cineva clears its local caches because OpenList caches storage listings on
  /// the server. We deliberately obtain a short-lived login token only for this
  /// manual refresh and never persist it. If the account has 2FA enabled, lacks
  /// refresh permission, or the server is not OpenList/AList-compatible, normal
  /// forced WebDAV refresh continues as a safe fallback.
  private func refreshOpenListDirectoryCache(
    configuration: WebDAVMountConfiguration,
    logicalPath: String
  ) async -> Bool {
    guard !configuration.username.isEmpty,
      let baseURL = openListBaseURL(configuration: configuration)
    else { return false }

    do {
      let loginURL = baseURL
        .appending(path: "api")
        .appending(path: "auth")
        .appending(path: "login")
      var loginRequest = URLRequest(url: loginURL)
      loginRequest.httpMethod = "POST"
      loginRequest.timeoutInterval = 15
      loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      loginRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      loginRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      loginRequest.httpBody = try JSONSerialization.data(withJSONObject: [
        "username": configuration.username,
        "password": configuration.password,
        "otp_code": "",
      ])

      let (loginData, loginResponse) = try await session.data(for: loginRequest)
      guard let loginHTTP = loginResponse as? HTTPURLResponse,
        (200...299).contains(loginHTTP.statusCode),
        let loginJSON = try JSONSerialization.jsonObject(with: loginData) as? [String: Any],
        (loginJSON["code"] as? NSNumber)?.intValue == 200,
        let loginPayload = loginJSON["data"] as? [String: Any],
        let token = loginPayload["token"] as? String,
        !token.isEmpty
      else { return false }

      let listURL = baseURL
        .appending(path: "api")
        .appending(path: "fs")
        .appending(path: "list")
      var listRequest = URLRequest(url: listURL)
      listRequest.httpMethod = "POST"
      listRequest.timeoutInterval = 25
      listRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      listRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
      listRequest.setValue(token, forHTTPHeaderField: "Authorization")
      listRequest.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
      listRequest.setValue("no-cache", forHTTPHeaderField: "Pragma")
      listRequest.httpBody = try JSONSerialization.data(withJSONObject: [
        "path": normalizeLogicalPath(logicalPath),
        "password": "",
        "page": 1,
        "per_page": 1,
        "refresh": true,
      ])

      let (listData, listResponse) = try await session.data(for: listRequest)
      guard let listHTTP = listResponse as? HTTPURLResponse,
        (200...299).contains(listHTTP.statusCode),
        let listJSON = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
        (listJSON["code"] as? NSNumber)?.intValue == 200
      else { return false }
      return true
    } catch {
      return false
    }
  }

  private func openListBaseURL(configuration: WebDAVMountConfiguration) -> URL? {
    guard let webDAVURL = configuration.normalizedWebDAVURL,
      var components = URLComponents(url: webDAVURL, resolvingAgainstBaseURL: false)
    else { return nil }

    var segments = components.path.split(separator: "/").map(String.init)
    if segments.last?.lowercased() == "dav" {
      segments.removeLast()
    }
    components.path = segments.isEmpty ? "/" : "/" + segments.joined(separator: "/")
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private func fetchDirectory(
    configuration: WebDAVMountConfiguration,
    logicalPath: String
  ) async throws -> [CloudItem] {
    let entries = try await fetchDirectoryEntries(
      configuration: configuration,
      logicalPath: logicalPath
    )
    return entries
      .filter { $0.isDirectory || $0.isVideo || $0.isPhoto }
      .sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  private func fetchDirectoryEntries(
    configuration: WebDAVMountConfiguration,
    logicalPath: String
  ) async throws -> [CloudItem] {
    let normalized = normalizeLogicalPath(logicalPath)
    let rawKey = configuration.cacheNamespace + "|raw|" + normalized
    if let cached = rawDirectoryCache[rawKey] { return cached }

    let data = try await performPROPFIND(
      configuration: configuration,
      logicalPath: normalized,
      depth: "1"
    )

    let parser = WebDAVMultiStatusParser(
      webDAVBasePath: configuration.webDAVBasePath,
      requestedLogicalPath: normalized
    )
    guard parser.parse(data: data) else {
      throw CloudProviderError.responseChanged(endpoint: "WebDAV 目录")
    }
    rawDirectoryCache[rawKey] = parser.items
    return parser.items
  }

  private func performDataRequestWithRecovery(
    _ request: URLRequest,
    acceptedStatusCodes: Set<Int>,
    attempts: Int = 3
  ) async throws -> (Data, HTTPURLResponse) {
    var lastError: Error?
    for attempt in 0..<max(1, attempts) {
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw CloudProviderError.network("OpenList / AList 没有返回有效网络响应。")
        }
        if acceptedStatusCodes.contains(http.statusCode) { return (data, http) }
        let transient = http.statusCode == 408 || http.statusCode == 425 || http.statusCode == 429 || (500...599).contains(http.statusCode)
        if transient, attempt + 1 < attempts {
          let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
          let backoff = retryAfter ?? min(pow(2.0, Double(attempt)) * 0.35, 1.4)
          try await Task.sleep(for: .milliseconds(Int(backoff * 1000)))
          continue
        }
        return (data, http)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        if attempt + 1 < attempts, isTransientNetworkError(error) {
          let backoff = min(pow(2.0, Double(attempt)) * 0.30, 1.2)
          try await Task.sleep(for: .milliseconds(Int(backoff * 1000)))
          continue
        }
        throw error
      }
    }
    throw lastError ?? CloudProviderError.network("网络连接异常，请稍后重试。")
  }

  private func isTransientNetworkError(_ error: Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed, .resourceUnavailable:
      return true
    default:
      return false
    }
  }

  private func fetchResourceData(
    configuration: WebDAVMountConfiguration,
    logicalPath: String,
    maximumBytes: Int
  ) async throws -> Data {
    let url = try webDAVURL(
      configuration: configuration,
      logicalPath: logicalPath,
      isDirectory: false
    )
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 25
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    if let authorization = configuration.authorizationHeader {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    let (data, http) = try await performDataRequestWithRecovery(request, acceptedStatusCodes: Set(200...299))
    guard (200...299).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw CloudProviderError.authenticationRequired("OpenList / AList 登录信息已失效或没有读取权限。")
      }
      if http.statusCode == 429 {
        throw CloudProviderError.rateLimited("媒体服务器请求过于频繁，Cineva 已自动退避重试。")
      }
      throw CloudProviderError.network("本地元数据读取失败（\(http.statusCode)）。")
    }
    guard data.count <= maximumBytes else {
      throw CloudProviderError.invalidResponse("本地元数据文件过大")
    }
    return data
  }

  private func performPROPFIND(
    configuration: WebDAVMountConfiguration,
    logicalPath: String,
    depth: String
  ) async throws -> Data {
    try await throttleMetadataRequests()
    let url = try webDAVURL(configuration: configuration, logicalPath: logicalPath, isDirectory: true)

    var request = URLRequest(url: url)
    request.httpMethod = "PROPFIND"
    request.timeoutInterval = 30
    request.setValue(depth, forHTTPHeaderField: "Depth")
    request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    if let authorization = configuration.authorizationHeader {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = Data(Self.propfindBody.utf8)

    let (data, http) = try await performDataRequestWithRecovery(request, acceptedStatusCodes: [200, 207])

    switch http.statusCode {
    case 200, 207:
      return data
    case 401, 403:
      throw CloudProviderError.authenticationRequired(
        "OpenList / AList 登录信息无效，或当前用户未开启 WebDAV 读取权限。"
      )
    case 404:
      throw CloudProviderError.remote(
        code: Int64(http.statusCode),
        message: "找不到挂载路径，请检查媒体库路径。"
      )
    case 405:
      throw CloudProviderError.remote(
        code: Int64(http.statusCode),
        message: "服务器未开放 WebDAV PROPFIND，请确认地址以 /dav/ 结尾。"
      )
    case 429:
      throw CloudProviderError.rateLimited("OpenList / AList 服务器请求过于频繁，请稍后再试。")
    case 500...599:
      throw CloudProviderError.network("OpenList / AList 服务器暂时不可用（\(http.statusCode)）。")
    default:
      let text = String(data: data.prefix(512), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw CloudProviderError.remote(
        code: Int64(http.statusCode),
        message: text.isEmpty ? "WebDAV 请求失败。" : text
      )
    }
  }

  private func throttleMetadataRequests() async throws {
    let minimumGap: TimeInterval = 0.12
    let elapsed = Date().timeIntervalSince(lastRequestAt)
    if elapsed < minimumGap {
      try await Task.sleep(for: .milliseconds(Int((minimumGap - elapsed) * 1000)))
    }
    lastRequestAt = Date()
  }

  private func webDAVURL(
    configuration: WebDAVMountConfiguration,
    logicalPath: String,
    isDirectory: Bool = false
  ) throws -> URL {
    guard var url = configuration.normalizedWebDAVURL else {
      throw CloudProviderError.invalidResponse("WebDAV 地址")
    }
    let normalized = normalizeLogicalPath(logicalPath)
    for segment in normalized.split(separator: "/", omittingEmptySubsequences: true) {
      url.append(path: String(segment))
    }
    if isDirectory, !url.absoluteString.hasSuffix("/") {
      guard let directoryURL = URL(string: url.absoluteString + "/") else {
        throw CloudProviderError.invalidResponse("WebDAV 地址")
      }
      return directoryURL
    }
    return url
  }

  private func normalizeLogicalPath(_ raw: String) -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return "/" }
    if !value.hasPrefix("/") { value = "/" + value }
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }

  private func cacheFileURL(cacheKey: String) -> URL {
    cacheDirectory.appending(path: "\(stableHash(cacheKey)).json")
  }

  private func readDiskCache(cacheKey: String) -> [CloudItem]? {
    guard let data = try? Data(contentsOf: cacheFileURL(cacheKey: cacheKey)) else { return nil }
    return try? JSONDecoder().decode([CloudItem].self, from: data)
  }

  private func writeDiskCache(_ items: [CloudItem], cacheKey: String) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    try? data.write(to: cacheFileURL(cacheKey: cacheKey), options: .atomic)
  }

  private static func parseChapterTimestamp(_ raw: String) -> Double? {
    let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":")
    guard parts.count >= 2 else { return nil }
    let seconds = Double(String(parts.last!)) ?? 0
    let minutes = Double(String(parts[parts.count - 2])) ?? 0
    let hours = parts.count >= 3 ? (Double(String(parts[parts.count - 3])) ?? 0) : 0
    return hours * 3600 + minutes * 60 + seconds
  }

  private func stableHash(_ value: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    return String(hash, radix: 16)
  }

  private static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:resourcetype/>
        <d:getcontentlength/>
        <d:creationdate/>
        <d:getlastmodified/>
        <d:getetag/>
        <d:getcontenttype/>
      </d:prop>
    </d:propfind>
    """
}

private struct ParsedNFO {
  var title: String?
  var plot: String?
  var year: String?
  var genre: String?
  var studio: String?
  var showTitle: String?
  var season: Int?
  var episode: Int?
  var director: String?
  var rating: String?
}

private final class SimpleNFOParser: NSObject, XMLParserDelegate {
  private var currentElement = ""
  private var buffer = ""
  private var result = ParsedNFO()

  static func parse(data: Data) -> ParsedNFO {
    let parserDelegate = SimpleNFOParser()
    let parser = XMLParser(data: data)
    parser.delegate = parserDelegate
    _ = parser.parse()
    return parserDelegate.result
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = elementName.lowercased()
    buffer = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    buffer += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    switch elementName.lowercased() {
    case "title": if result.title == nil { result.title = value }
    case "plot", "outline": if result.plot == nil { result.plot = value }
    case "year": if result.year == nil { result.year = value }
    case "genre": if result.genre == nil { result.genre = value }
    case "studio": if result.studio == nil { result.studio = value }
    case "showtitle": if result.showTitle == nil { result.showTitle = value }
    case "season": if result.season == nil { result.season = Int(value) }
    case "episode": if result.episode == nil { result.episode = Int(value) }
    case "director": if result.director == nil { result.director = value }
    case "rating": if result.rating == nil { result.rating = value }
    default: break
    }
    buffer = ""
  }
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
  private struct Entry {
    var href = ""
    var displayName = ""
    var contentLength: Int64 = 0
    var creationDate = ""
    var lastModified = ""
    var etag = ""
    var contentType = ""
    var isCollection = false
  }

  private let webDAVBasePath: String
  private let requestedLogicalPath: String
  private var currentEntry: Entry?
  private var currentElement = ""
  private var textBuffer = ""
  private(set) var items: [CloudItem] = []

  init(webDAVBasePath: String, requestedLogicalPath: String) {
    self.webDAVBasePath = Self.normalizeServerPath(webDAVBasePath)
    self.requestedLogicalPath = Self.normalizeLogicalPath(requestedLogicalPath)
  }

  func parse(data: Data) -> Bool {
    let parser = XMLParser(data: data)
    parser.delegate = self
    return parser.parse()
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = Self.localName(elementName)
    currentElement = name
    textBuffer = ""
    if name == "response" {
      currentEntry = Entry()
    } else if name == "collection" {
      currentEntry?.isCollection = true
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    textBuffer += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = Self.localName(elementName)
    let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

    switch name {
    case "href": currentEntry?.href = value
    case "displayname": currentEntry?.displayName = value
    case "getcontentlength": currentEntry?.contentLength = Int64(value) ?? 0
    case "creationdate": currentEntry?.creationDate = value
    case "getlastmodified": currentEntry?.lastModified = value
    case "getetag": currentEntry?.etag = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    case "getcontenttype": currentEntry?.contentType = value
    case "response":
      if let entry = currentEntry, let item = makeCloudItem(entry) {
        items.append(item)
      }
      currentEntry = nil
    default: break
    }

    currentElement = ""
    textBuffer = ""
  }

  private func makeCloudItem(_ entry: Entry) -> CloudItem? {
    guard !entry.href.isEmpty else { return nil }
    let logicalPath = logicalPath(from: entry.href)
    guard logicalPath != requestedLogicalPath else { return nil }
    guard logicalPath.hasPrefix(requestedLogicalPath == "/" ? "/" : requestedLogicalPath + "/") else {
      return nil
    }

    let pathName = URL(fileURLWithPath: logicalPath).lastPathComponent
    let displayName = entry.displayName.removingPercentEncoding ?? entry.displayName
    let name = displayName.isEmpty ? (pathName.removingPercentEncoding ?? pathName) : displayName
    let ext = entry.isCollection ? "" : URL(fileURLWithPath: name).pathExtension.lowercased()
    let isVideo = Self.videoExtensions.contains(ext)
    let parent = Self.parentPath(logicalPath)

    return CloudItem(
      id: logicalPath,
      parentID: parent,
      name: name.isEmpty ? "未命名" : name,
      isDirectory: entry.isCollection,
      pickCode: logicalPath,
      sha1: entry.etag,
      size: entry.contentLength,
      fileExtension: ext,
      isVideo: isVideo,
      duration: 0,
      thumbnailURLString: nil,
      modifiedAt: Self.parseHTTPDate(entry.lastModified) ?? .distantPast,
      createdAt: Self.parseCreationDate(entry.creationDate)
    )
  }

  private func logicalPath(from href: String) -> String {
    let rawPath: String
    if let url = URL(string: href), url.scheme != nil {
      rawPath = url.path
    } else {
      rawPath = href.components(separatedBy: "?").first ?? href
    }
    let decoded = rawPath.removingPercentEncoding ?? rawPath
    let normalized = Self.normalizeServerPath(decoded)
    if webDAVBasePath != "/", normalized.hasPrefix(webDAVBasePath) {
      let suffix = String(normalized.dropFirst(webDAVBasePath.count))
      return Self.normalizeLogicalPath(suffix.isEmpty ? "/" : suffix)
    }
    return Self.normalizeLogicalPath(normalized)
  }

  private static func localName(_ element: String) -> String {
    element.split(separator: ":").last.map(String.init)?.lowercased() ?? element.lowercased()
  }

  private static func normalizeServerPath(_ raw: String) -> String {
    var value = raw.isEmpty ? "/" : raw
    if !value.hasPrefix("/") { value = "/" + value }
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }

  private static func normalizeLogicalPath(_ raw: String) -> String {
    normalizeServerPath(raw)
  }

  private static func parentPath(_ path: String) -> String {
    let normalized = normalizeLogicalPath(path)
    guard normalized != "/" else { return "/" }
    let parent = (normalized as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : normalizeLogicalPath(parent)
  }

  private static func parseHTTPDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    return httpDateFormatter.date(from: value)
  }

  private static func parseCreationDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    return creationDateFormatter.date(from: value)
  }

  private static let creationDateFormatter = ISO8601DateFormatter()

  private static let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter
  }()

  private static let videoExtensions: Set<String> = [
    "mp4", "m4v", "mov", "mkv", "avi", "flv", "rmvb", "wmv",
    "m2ts", "mts", "ts", "webm", "mpg", "mpeg", "3gp", "vob", "iso", "img",
  ]
}
