import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

actor WebDAVProvider: CloudProvider {
  static let shared = WebDAVProvider()
  static let userAgent = "Cineva-iOS/2.0"

  private let store = WebDAVCredentialStore.shared
  private let session: URLSession
  private var memoryCache: [String: [CloudItem]] = [:]
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

    let start = min(max(offset, 0), allItems.count)
    let end = min(start + safeLimit, allItems.count)
    let pageItems = Array(allItems[start..<end])

    return CloudFolderPage(
      items: pageItems,
      offset: start,
      limit: safeLimit,
      total: allItems.count,
      hasMore: end < allItems.count,
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

  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async {
    // OpenList/AList WebDAV is intentionally read-only from Cineva.
    // Playback progress remains in Cineva's local LibraryStore.
  }

  func clearMountCache() async {
    memoryCache.removeAll()
    try? FileManager.default.removeItem(at: cacheDirectory)
    try? FileManager.default.createDirectory(
      at: cacheDirectory,
      withIntermediateDirectories: true
    )
  }

  private func fetchDirectory(
    configuration: WebDAVMountConfiguration,
    logicalPath: String
  ) async throws -> [CloudItem] {
    let data = try await performPROPFIND(
      configuration: configuration,
      logicalPath: logicalPath,
      depth: "1"
    )

    let parser = WebDAVMultiStatusParser(
      webDAVBasePath: configuration.webDAVBasePath,
      requestedLogicalPath: logicalPath
    )
    guard parser.parse(data: data) else {
      throw CloudProviderError.responseChanged(endpoint: "WebDAV 目录")
    }

    return parser.items
      .filter { $0.isDirectory || $0.isVideo }
      .sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
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
    if let authorization = configuration.authorizationHeader {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    request.httpBody = Data(Self.propfindBody.utf8)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CloudProviderError.network("OpenList / AList 没有返回有效网络响应。")
    }

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
        <d:getlastmodified/>
        <d:getetag/>
        <d:getcontenttype/>
      </d:prop>
    </d:propfind>
    """
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
  private struct Entry {
    var href = ""
    var displayName = ""
    var contentLength: Int64 = 0
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
      modifiedAt: Self.parseHTTPDate(entry.lastModified) ?? .distantPast
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
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    return formatter.date(from: value)
  }

  private static let videoExtensions: Set<String> = [
    "mp4", "m4v", "mov", "mkv", "avi", "flv", "rmvb", "wmv",
    "m2ts", "mts", "ts", "webm", "mpg", "mpeg", "3gp", "vob",
  ]
}
