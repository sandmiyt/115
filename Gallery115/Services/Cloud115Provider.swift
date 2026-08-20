import Foundation

actor Cloud115Provider: CloudProvider {
  static let shared = Cloud115Provider()
  static let userAgent = "Cineva-iOS/2.0"

  private let baseURL = URL(string: "https://proapi.115.com")!
  private let auth = Cloud115AuthManager.shared
  private let session: URLSession
  private let mountCache = Cloud115MountCache()
  private var nextRequestSlot: TimeInterval = 0
  private let requestInterval: TimeInterval = 0.55

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 60
    config.requestCachePolicy = .reloadRevalidatingCacheData
    config.urlCache = URLCache(
      memoryCapacity: 64 * 1024 * 1024,
      diskCapacity: 512 * 1024 * 1024,
      diskPath: "Cineva115URLCache"
    )
    session = URLSession(configuration: config)
  }

  func validateCredentials() async throws {
    do {
      _ = try await authorizedRequest(path: "/open/user/info", method: "GET")
      return
    } catch let error as CloudProviderError {
      // Some 115 edge gateways intermittently return 405/HTML for the user-info probe.
      // Only a confirmed authentication failure should stop here; otherwise validate
      // the same OAuth session with a tiny root-folder request instead.
      if case .authenticationRequired = error { throw error }
    }

    _ = try await authorizedRequest(
      path: "/open/ufile/files",
      method: "GET",
      query: [
        "cid": "0",
        "limit": "1",
        "offset": "0",
        "asc": "0",
        "o": "user_utime",
        "custom_order": "0",
        "stdir": "1",
        "star": "0",
        "cur": "0",
        "show_dir": "1",
      ]
    )
  }

  func listFolderPage(
    id: String,
    offset: Int,
    limit: Int,
    forceRefresh: Bool
  ) async throws -> CloudFolderPage {
    let safeOffset = max(offset, 0)
    let safeLimit = min(max(limit, 1), 56)

    if !forceRefresh,
      let cached = mountCache.page(folderID: id, offset: safeOffset, limit: safeLimit),
      Date().timeIntervalSince(cached.savedAt) < 300
    {
      return cached.folderPage(servedFromCache: true)
    }

    do {
      let data = try await authorizedRequest(
        path: "/open/ufile/files",
        method: "GET",
        query: [
          "cid": id,
          "limit": String(safeLimit),
          "offset": String(safeOffset),
          "asc": "0",
          "o": "user_utime",
          "custom_order": "0",
          "stdir": "1",
          "star": "0",
          "cur": "0",
          "show_dir": "1",
        ]
      )

      let parsed = try parseFileList(data, endpoint: "资料库")
      let total = parsed.total
      let hasMore: Bool
      if let total, total > 0 {
        hasMore = safeOffset + parsed.rawRecordCount < total && parsed.rawRecordCount > 0
      } else {
        hasMore = parsed.rawRecordCount >= safeLimit
      }

      let cached = CachedCloud115Page(
        folderID: id,
        offset: safeOffset,
        limit: safeLimit,
        items: parsed.items.filter { $0.isDirectory || $0.isVideo },
        total: total,
        hasMore: hasMore,
        savedAt: Date()
      )
      mountCache.save(cached)
      return cached.folderPage(servedFromCache: false)
    } catch {
      // A mounted source should remain browsable during temporary 115/WAF failures.
      // Prefer stale data over replacing a working library with an error screen.
      if let cached = mountCache.page(folderID: id, offset: safeOffset, limit: safeLimit) {
        return cached.folderPage(servedFromCache: true)
      }
      throw error
    }
  }

  func clearMountCache() async {
    mountCache.clear()
  }

  func videoSources(for item: CloudItem) async throws -> [VideoSource] {
    guard !item.pickCode.isEmpty else {
      throw CloudProviderError.noPlayableSource
    }

    var sources: [VideoSource] = []
    var transcodeError: Error?

    do {
      sources = try await transcodedSources(pickCode: item.pickCode)
    } catch let error as CloudProviderError {
      // Authentication and rate-limit errors are meaningful and must not be swallowed.
      switch error {
      case .authenticationRequired, .rateLimited:
        throw error
      default:
        transcodeError = error
      }
    } catch {
      transcodeError = error
    }

    if let original = try? await originalSource(pickCode: item.pickCode) {
      sources.append(original)
    }

    let unique = Dictionary(grouping: sources, by: \.id).compactMap { $0.value.first }
    let sorted = unique.sorted { lhs, rhs in
      if lhs.isOriginal != rhs.isOriginal { return !lhs.isOriginal }
      return lhs.definition > rhs.definition
    }

    if !sorted.isEmpty { return sorted }
    if let transcodeError { throw transcodeError }
    throw CloudProviderError.noPlayableSource
  }

  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async {
    guard !pickCode.isEmpty else { return }
    _ = try? await authorizedRequest(
      path: "/open/video/history",
      method: "POST",
      form: [
        "pick_code": pickCode,
        "time": String(max(0, seconds)),
        "watch_end": watchEnd ? "1" : "0",
      ]
    )
  }

  private func transcodedSources(pickCode: String) async throws -> [VideoSource] {
    let data = try await authorizedRequest(
      path: "/open/video/play",
      method: "GET",
      query: ["pick_code": pickCode]
    )

    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CloudProviderError.invalidResponse("视频播放地址")
    }
    guard let payload = object["data"] as? [String: Any] else {
      return []
    }

    let rawVideoURL = payload["video_url"]
    let candidates: [[String: Any]]
    if let array = rawVideoURL as? [[String: Any]] {
      candidates = array
    } else if let dictionary = rawVideoURL as? [String: Any] {
      candidates = dictionary.values.compactMap { $0 as? [String: Any] }
    } else {
      candidates = []
    }

    return candidates.compactMap { candidate in
      let rawURL: String
      if let nested = candidate["url"] as? [String: Any] {
        rawURL = cloud115String(nested["url"])
      } else {
        rawURL = cloud115String(candidate["url"])
      }
      guard let url = URL(string: rawURL), !rawURL.isEmpty else { return nil }

      let definition = Int(cloud115Int64(candidate["definition"]))
      let desc = cloud115String(candidate["desc"])
      let title = desc.isEmpty ? definitionTitle(definition) : desc
      return VideoSource(
        id: "transcode-\(definition)-\(rawURL.hashValue)",
        title: title,
        definition: definition,
        url: url,
        kind: .transcoded,
        headers: ["User-Agent": Self.userAgent]
      )
    }
  }

  private func originalSource(pickCode: String) async throws -> VideoSource {
    let data = try await authorizedRequest(
      path: "/open/ufile/downurl",
      method: "POST",
      form: ["pick_code": pickCode],
      extraHeaders: ["User-Agent": Self.userAgent]
    )

    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let payload = object["data"] as? [String: Any]
    else {
      throw CloudProviderError.missingOriginalURL
    }

    for rawEntry in payload.values {
      guard let entry = rawEntry as? [String: Any] else { continue }
      let rawURL: String
      if let nested = entry["url"] as? [String: Any] {
        rawURL = cloud115String(nested["url"])
      } else {
        rawURL = cloud115String(entry["url"])
      }
      if let url = URL(string: rawURL), !rawURL.isEmpty {
        return VideoSource(
          id: "original-\(pickCode)",
          title: "原画",
          definition: 100,
          url: url,
          kind: .original,
          headers: ["User-Agent": Self.userAgent]
        )
      }
    }

    throw CloudProviderError.missingOriginalURL
  }

  private func authorizedRequest(
    path: String,
    method: String,
    query: [String: String] = [:],
    form: [String: String]? = nil,
    extraHeaders: [String: String] = [:]
  ) async throws -> Data {
    var didRefresh = false
    var transientAttempt = 0

    while true {
      let accessToken = try await auth.accessToken()
      let result: (Data, HTTPURLResponse)
      do {
        result = try await performRequest(
          path: path,
          method: method,
          query: query,
          form: form,
          extraHeaders: extraHeaders,
          accessToken: accessToken
        )
      } catch let error as URLError {
        if transientAttempt < 1 {
          transientAttempt += 1
          try? await Task.sleep(for: .milliseconds(350))
          continue
        }
        throw CloudProviderError.network(error.localizedDescription)
      } catch let error as CloudProviderError {
        throw error
      } catch {
        throw CloudProviderError.network(error.localizedDescription)
      }

      let data = result.0
      let http = result.1

      if http.statusCode == 401 || http.statusCode == 403 {
        if !didRefresh {
          _ = try await auth.refreshSession()
          didRefresh = true
          continue
        }
        throw CloudProviderError.authenticationRequired(
          "115 登录状态已失效，请重新连接 115 网盘。"
        )
      }

      if http.statusCode == 405 {
        // 115 edge/WAF occasionally responds with HTML 405 when access protection is
        // triggered. All Cineva methods are verified against the Open API, so treat
        // this as temporary overload rather than an instruction to log the user out.
        if transientAttempt < 2 {
          transientAttempt += 1
          try? await Task.sleep(for: .milliseconds(1100 * transientAttempt))
          continue
        }
        throw CloudProviderError.rateLimited(
          "115 当前访问保护已触发，Cineva 将继续使用本地资料库缓存。"
        )
      }

      if http.statusCode == 429 {
        if transientAttempt < 2 {
          transientAttempt += 1
          try? await Task.sleep(for: .milliseconds(1200 * transientAttempt))
          continue
        }
        throw CloudProviderError.rateLimited("115 请求过于频繁，请稍后再试。")
      }

      if http.statusCode >= 500 {
        if transientAttempt < 1 {
          transientAttempt += 1
          try? await Task.sleep(for: .milliseconds(450))
          continue
        }
        throw CloudProviderError.network("115 服务暂时不可用，请稍后再试。")
      }

      guard (200..<500).contains(http.statusCode) else {
        throw CloudProviderError.invalidResponse(path)
      }

      let status = parseStatus(from: data, httpStatus: http.statusCode)
      if !status.state {
        if isAuthenticationCode(status.code, message: status.message) {
          if !didRefresh {
            _ = try await auth.refreshSession()
            didRefresh = true
            continue
          }
          throw CloudProviderError.authenticationRequired(
            "115 登录状态已失效，请重新连接 115 网盘。"
          )
        }

        if isRateLimitCode(status.code, message: status.message) {
          if transientAttempt < 2 {
            transientAttempt += 1
            try? await Task.sleep(for: .milliseconds(1200 * transientAttempt))
            continue
          }
          throw CloudProviderError.rateLimited(status.message)
        }
        throw CloudProviderError.remote(code: status.code, message: status.message)
      }

      return data
    }
  }

  private func performRequest(
    path: String,
    method: String,
    query: [String: String],
    form: [String: String]?,
    extraHeaders: [String: String],
    accessToken: String
  ) async throws -> (Data, HTTPURLResponse) {
    var components = URLComponents(
      url: baseURL.appending(path: path),
      resolvingAgainstBaseURL: false
    )
    if !query.isEmpty {
      components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components?.url else {
      throw CloudProviderError.invalidResponse(path)
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

    if let form {
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = form.cloud115FormEncoded.data(using: .utf8)
    }

    await waitForRequestSlot()
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudProviderError.invalidResponse(path)
    }
    return (data, http)
  }

  private func waitForRequestSlot() async {
    let now = Date().timeIntervalSinceReferenceDate
    let scheduled = max(now, nextRequestSlot)
    nextRequestSlot = scheduled + requestInterval
    let delay = scheduled - now
    if delay > 0 {
      try? await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
    }
  }

  private func parseStatus(from data: Data, httpStatus: Int) -> Cloud115Status {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      // Successful binary/text bodies are allowed only when the endpoint does not use an envelope.
      return Cloud115Status(
        state: (200..<300).contains(httpStatus),
        code: Int64(httpStatus),
        message: (200..<300).contains(httpStatus) ? "" : "115 返回了非 JSON 响应。"
      )
    }

    let code = cloud115Int64(object["code"])
    let message = [
      cloud115String(object["message"]),
      cloud115String(object["error"]),
      cloud115String(object["error_description"]),
      cloud115String(object["text"]),
    ].first(where: { !$0.isEmpty }) ?? "未知错误"

    if let rawState = object["state"] {
      return Cloud115Status(
        state: cloud115Bool(rawState),
        code: code,
        message: message
      )
    }

    // Some 115 endpoints omit `state` on successful responses. HTTP success + data is
    // treated as success instead of generating a false decoding error.
    let inferredSuccess = (200..<300).contains(httpStatus)
      && (object["data"] != nil || code == 0)
    return Cloud115Status(state: inferredSuccess, code: code, message: message)
  }

  private func parseFileList(_ data: Data, endpoint: String) throws -> Cloud115FilePage {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CloudProviderError.invalidResponse(endpoint)
    }

    let dataContainer = object["data"] as? [String: Any]
    let rawRecords: [Any]
    if let direct = object["data"] as? [Any] {
      rawRecords = direct
    } else if let nested = dataContainer?["data"] as? [Any] {
      rawRecords = nested
    } else if object["data"] == nil || object["data"] is NSNull {
      rawRecords = []
    } else {
      // A changed `data` shape should not surface as Swift's generic DecodingError.
      throw CloudProviderError.responseChanged(endpoint: endpoint)
    }

    let items = rawRecords.compactMap { raw -> CloudItem? in
      guard let record = raw as? [String: Any] else { return nil }
      return cloudItem(from: record)
    }

    let countValue = object["count"] ?? dataContainer?["count"]
    let count = Int(cloud115Int64(countValue))
    return Cloud115FilePage(
      items: items,
      total: count > 0 ? count : nil,
      rawRecordCount: rawRecords.count
    )
  }

  private func cloudItem(from record: [String: Any]) -> CloudItem? {
    let fid = cloud115String(record["fid"])
    let pid = cloud115String(record["pid"])
    let fc = cloud115String(record["fc"])
    let name = cloud115String(record["fn"])
    let fco = cloud115String(record["fco"])
    let pickCode = cloud115String(record["pc"])
    let sha1 = cloud115String(record["sha1"])
    let size = cloud115Int64(record["fs"])
    let fileExtension = cloud115String(record["ico"])
    let isVideoFlag = cloud115Int64(record["isv"])
    let duration = cloud115Double(record["play_long"])
    let videoImage = cloud115String(record["v_img"])
    let thumb = cloud115String(record["thumb"])
    let updatedAt = cloud115Double(record["upt"])

    let isDirectory = fc == "0"
    let isVideo = isVideoFlag == 1 || Self.videoExtensions.contains(fileExtension.lowercased())
    guard isDirectory || isVideo else { return nil }
    guard !fid.isEmpty || !pickCode.isEmpty else { return nil }

    let thumbnail = [videoImage, thumb, fco].first(where: { !$0.isEmpty })
    return CloudItem(
      id: fid.isEmpty ? pickCode : fid,
      parentID: pid,
      name: name.isEmpty ? "未命名视频" : name,
      isDirectory: isDirectory,
      pickCode: pickCode,
      sha1: sha1,
      size: size,
      fileExtension: fileExtension,
      isVideo: isVideo,
      duration: duration,
      thumbnailURLString: thumbnail,
      modifiedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }

  private func isAuthenticationCode(_ code: Int64, message: String) -> Bool {
    let text = message.lowercased()
    return code == 99
      || String(code).hasPrefix("401")
      || text.contains("token") && (text.contains("invalid") || text.contains("expired"))
      || text.contains("no auth")
  }

  private func isRateLimitCode(_ code: Int64, message: String) -> Bool {
    let text = message.lowercased()
    return code == 770004
      || text.contains("too many")
      || text.contains("频繁")
      || text.contains("上限")
  }

  private func definitionTitle(_ definition: Int) -> String {
    switch definition {
    case 1: return "标清"
    case 2: return "高清"
    case 3: return "超清"
    case 4: return "1080P"
    case 5: return "4K"
    default: return definition > 0 ? "清晰度 \(definition)" : "自动"
    }
  }

  private static let videoExtensions: Set<String> = [
    "mp4", "mkv", "mov", "m4v", "avi", "flv", "rmvb", "wmv", "m2ts", "mts", "ts", "webm",
  ]
}

private struct Cloud115Status {
  let state: Bool
  let code: Int64
  let message: String
}

private struct Cloud115FilePage {
  let items: [CloudItem]
  let total: Int?
  let rawRecordCount: Int
}

private struct CachedCloud115Page: Codable {
  let folderID: String
  let offset: Int
  let limit: Int
  let items: [CloudItem]
  let total: Int?
  let hasMore: Bool
  let savedAt: Date

  func folderPage(servedFromCache: Bool) -> CloudFolderPage {
    CloudFolderPage(
      items: items,
      offset: offset,
      limit: limit,
      total: total,
      hasMore: hasMore,
      servedFromCache: servedFromCache
    )
  }
}

private final class Cloud115MountCache: @unchecked Sendable {
  private let fileManager = FileManager.default
  private let directory: URL
  private let lock = NSLock()

  init() {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
    directory = base.appending(path: "CinevaMountCache/115", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func page(folderID: String, offset: Int, limit: Int) -> CachedCloud115Page? {
    lock.lock()
    defer { lock.unlock() }
    let url = fileURL(folderID: folderID, offset: offset, limit: limit)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(CachedCloud115Page.self, from: data)
  }

  func save(_ page: CachedCloud115Page) {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? JSONEncoder().encode(page) else { return }
    try? data.write(
      to: fileURL(folderID: page.folderID, offset: page.offset, limit: page.limit),
      options: .atomic
    )
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    try? fileManager.removeItem(at: directory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  private func fileURL(folderID: String, offset: Int, limit: Int) -> URL {
    let safeID = folderID.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
    }.joined()
    return directory.appending(path: "page-\(safeID)-\(offset)-\(limit).json")
  }
}

private func cloud115Bool(_ value: Any?) -> Bool {
  switch value {
  case let value as Bool: return value
  case let value as NSNumber: return value.intValue != 0
  case let value as String:
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "1" || normalized == "true" || normalized == "yes"
  default: return false
  }
}

private func cloud115Double(_ value: Any?) -> Double {
  switch value {
  case let value as NSNumber: return value.doubleValue
  case let value as String: return Double(value) ?? 0
  default: return 0
  }
}
