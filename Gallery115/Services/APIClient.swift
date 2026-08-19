import Foundation

actor APIClient {
  enum APIError: LocalizedError {
    case missingRefreshToken
    case invalidResponse
    case remote(code: Int64, message: String)
    case malformedData
    case missingOriginalURL

    var errorDescription: String? {
      switch self {
      case .missingRefreshToken: return "尚未配置 115 Refresh Token。"
      case .invalidResponse: return "115 返回了无法识别的响应。"
      case .remote(let code, let message): return "115 接口错误（\(code)）：\(message)"
      case .malformedData: return "115 返回的数据格式异常。"
      case .missingOriginalURL: return "没有取得该视频的原画地址。"
      }
    }
  }

  static let userAgent = "115Gallery-iOS/1.0"

  private let baseURL = URL(string: "https://proapi.115.com")!
  private let authURL = URL(string: "https://passportapi.115.com")!
  private let session: URLSession
  private let credentials = CredentialStore.shared

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 60
    config.requestCachePolicy = .reloadRevalidatingCacheData
    config.urlCache = URLCache(
      memoryCapacity: 64 * 1024 * 1024,
      diskCapacity: 512 * 1024 * 1024,
      diskPath: "Gallery115URLCache"
    )
    session = URLSession(configuration: config)
  }

  func validateCredentials() async throws {
    _ = try await authorizedRequest(path: "/open/user/info", method: "GET")
  }

  func listFolder(id: String) async throws -> [CloudItem] {
    var offset = 0
    let pageSize = 200
    var all: [CloudItem] = []
    var total = Int.max

    while offset < total {
      let data = try await authorizedRequest(
        path: "/open/ufile/files",
        method: "GET",
        query: [
          "cid": id,
          "limit": String(pageSize),
          "offset": String(offset),
          "asc": "0",
          "o": "user_utime",
          "custom_order": "0",
          "stdir": "1",
          "star": "0",
          "cur": "0",
          "show_dir": "1",
        ]
      )
      let response = try JSONDecoder.gallery115.decode(FileListResponse.self, from: data)
      total = response.count
      all.append(contentsOf: response.data.compactMap(\.cloudItem))
      offset += pageSize
      if response.data.isEmpty { break }
      if offset < total {
        try? await Task.sleep(for: .milliseconds(250))
      }
    }

    return all.filter { $0.isDirectory || $0.isVideo }
  }

  func videoSources(for item: CloudItem) async throws -> [VideoSource] {
    guard !item.pickCode.isEmpty else { return [] }

    async let transcodesTask = transcodedSources(pickCode: item.pickCode)
    async let originalTask = originalSource(pickCode: item.pickCode)

    let transcodes = (try? await transcodesTask) ?? []
    let original = try? await originalTask

    var sources = transcodes.sorted { $0.definition > $1.definition }
    if let original {
      sources.append(original)
    }
    return sources
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
    let envelope = try JSONDecoder.gallery115.decode(Envelope<VideoPlayData>.self, from: data)
    guard let payload = envelope.data else { return [] }
    return payload.videoURL.compactMap { candidate in
      guard let url = URL(string: candidate.url), !candidate.url.isEmpty else { return nil }
      let title = candidate.desc.isEmpty ? definitionTitle(candidate.definition) : candidate.desc
      return VideoSource(
        id: "transcode-\(candidate.definition)-\(candidate.url.hashValue)",
        title: title,
        definition: candidate.definition,
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
    let envelope = try JSONDecoder.gallery115.decode(
      Envelope<[String: DownloadEntry]>.self, from: data)
    guard let entry = envelope.data?.values.first,
      let url = URL(string: entry.url.url),
      !entry.url.url.isEmpty
    else {
      throw APIError.missingOriginalURL
    }
    return VideoSource(
      id: "original-\(pickCode)",
      title: "原画",
      definition: 100,
      url: url,
      kind: .original,
      headers: ["User-Agent": Self.userAgent]
    )
  }

  private func authorizedRequest(
    path: String,
    method: String,
    query: [String: String] = [:],
    form: [String: String]? = nil,
    extraHeaders: [String: String] = [:],
    allowRefresh: Bool = true
  ) async throws -> Data {
    if credentials.accessToken?.isEmpty != false {
      try await refreshAccessToken()
    }

    guard let accessToken = credentials.accessToken, !accessToken.isEmpty else {
      throw APIError.missingRefreshToken
    }

    var components = URLComponents(
      url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components.url else { throw APIError.invalidResponse }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    extraHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

    if let form {
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = form.formEncoded.data(using: .utf8)
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else {
      throw APIError.invalidResponse
    }

    let status = try parseStatus(from: data)
    if !status.state {
      if allowRefresh && (status.code == 99 || String(status.code).hasPrefix("401")) {
        try await refreshAccessToken()
        return try await authorizedRequest(
          path: path,
          method: method,
          query: query,
          form: form,
          extraHeaders: extraHeaders,
          allowRefresh: false
        )
      }
      throw APIError.remote(code: status.code, message: status.message)
    }
    return data
  }

  private func refreshAccessToken() async throws {
    guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
      throw APIError.missingRefreshToken
    }

    let url = authURL.appending(path: "/open/refreshToken")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = ["refresh_token": refreshToken].formEncoded.data(using: .utf8)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else {
      throw APIError.invalidResponse
    }

    let envelope = try JSONDecoder.gallery115.decode(AuthEnvelope<TokenPayload>.self, from: data)
    guard envelope.state == 1,
      let payload = envelope.data,
      !payload.accessToken.isEmpty,
      !payload.refreshToken.isEmpty
    else {
      throw APIError.remote(code: Int64(envelope.code), message: envelope.message)
    }
    credentials.save(accessToken: payload.accessToken, refreshToken: payload.refreshToken)
  }

  private func parseStatus(from data: Data) throws -> APIStatus {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw APIError.malformedData
    }
    let state = (object["state"] as? Bool) ?? ((object["state"] as? NSNumber)?.intValue == 1)
    let code: Int64
    if let value = object["code"] as? NSNumber {
      code = value.int64Value
    } else if let value = object["code"] as? String, let parsed = Int64(value) {
      code = parsed
    } else {
      code = 0
    }
    let message = (object["message"] as? String) ?? (object["error"] as? String) ?? "未知错误"
    return APIStatus(state: state, code: code, message: message)
  }

  private func definitionTitle(_ definition: Int) -> String {
    switch definition {
    case 1: return "标清"
    case 2: return "高清"
    case 3: return "超清"
    case 4: return "1080P"
    case 5: return "4K"
    default: return "清晰度 \(definition)"
    }
  }
}

private struct APIStatus {
  let state: Bool
  let code: Int64
  let message: String
}

private struct Envelope<T: Decodable>: Decodable {
  let state: Bool
  let code: Int64
  let message: String
  let data: T?
}

private struct AuthEnvelope<T: Decodable>: Decodable {
  let state: Int
  let code: Int
  let message: String
  let data: T?
}

private struct TokenPayload: Decodable {
  let accessToken: String
  let refreshToken: String

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
  }
}

private struct FileListResponse: Decodable {
  let state: Bool
  let code: Int64
  let message: String
  let data: [FileRecord]
  let count: Int
}

private struct FileRecord: Decodable {
  let fid: String
  let pid: String
  let fc: String
  let fn: String
  let fco: String
  let pc: String
  let sha1: String
  let fs: Int64
  let ico: String
  let isv: Int64
  let playLong: Double
  let vImg: String
  let thumb: String
  let upt: Int64

  enum CodingKeys: String, CodingKey {
    case fid, pid, fc, fn, fco, pc, sha1, fs, ico, isv, upt
    case playLong = "play_long"
    case vImg = "v_img"
    case thumb
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    fid = c.flexibleString(.fid)
    pid = c.flexibleString(.pid)
    fc = c.flexibleString(.fc)
    fn = c.flexibleString(.fn)
    fco = c.flexibleString(.fco)
    pc = c.flexibleString(.pc)
    sha1 = c.flexibleString(.sha1)
    fs = c.flexibleInt64(.fs)
    ico = c.flexibleString(.ico)
    isv = c.flexibleInt64(.isv)
    playLong = c.flexibleDouble(.playLong)
    vImg = c.flexibleString(.vImg)
    thumb = c.flexibleString(.thumb)
    upt = c.flexibleInt64(.upt)
  }

  var cloudItem: CloudItem? {
    let isDirectory = fc == "0"
    let isVideo =
      isv == 1
      || ["mp4", "mkv", "mov", "m4v", "avi", "flv", "rmvb", "wmv", "m2ts", "mts", "ts", "webm"]
        .contains(ico.lowercased())
    guard isDirectory || isVideo else { return nil }
    let thumbCandidate = [vImg, thumb, fco].first { !$0.isEmpty }
    return CloudItem(
      id: fid,
      parentID: pid,
      name: fn,
      isDirectory: isDirectory,
      pickCode: pc,
      sha1: sha1,
      size: fs,
      fileExtension: ico,
      isVideo: isVideo,
      duration: playLong,
      thumbnailURLString: thumbCandidate,
      modifiedAt: Date(timeIntervalSince1970: TimeInterval(upt))
    )
  }
}

private struct VideoPlayData: Decodable {
  let videoURL: [VideoURL]

  enum CodingKeys: String, CodingKey {
    case videoURL = "video_url"
  }
}

private struct VideoURL: Decodable {
  let url: String
  let definition: Int
  let desc: String
}

private struct DownloadEntry: Decodable {
  struct URLValue: Decodable {
    let url: String
  }

  let url: URLValue
}

extension JSONDecoder {
  fileprivate static var gallery115: JSONDecoder {
    let decoder = JSONDecoder()
    return decoder
  }
}

extension KeyedDecodingContainer {
  fileprivate func flexibleString(_ key: Key) -> String {
    if let value = try? decode(String.self, forKey: key) { return value }
    if let value = try? decode(Int64.self, forKey: key) { return String(value) }
    if let value = try? decode(Double.self, forKey: key) { return String(value) }
    return ""
  }

  fileprivate func flexibleInt64(_ key: Key) -> Int64 {
    if let value = try? decode(Int64.self, forKey: key) { return value }
    if let value = try? decode(Int.self, forKey: key) { return Int64(value) }
    if let value = try? decode(String.self, forKey: key) { return Int64(value) ?? 0 }
    if let value = try? decode(Double.self, forKey: key) { return Int64(value) }
    return 0
  }

  fileprivate func flexibleDouble(_ key: Key) -> Double {
    if let value = try? decode(Double.self, forKey: key) { return value }
    if let value = try? decode(Int64.self, forKey: key) { return Double(value) }
    if let value = try? decode(String.self, forKey: key) { return Double(value) ?? 0 }
    return 0
  }
}

extension Dictionary where Key == String, Value == String {
  fileprivate var formEncoded: String {
    map { key, value in
      "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
    }
    .sorted()
    .joined(separator: "&")
  }
}

extension String {
  fileprivate var urlFormEncoded: String {
    addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
  }
}

extension CharacterSet {
  fileprivate static let urlQueryValueAllowed: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()
}
