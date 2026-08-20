import Foundation

struct CloudFolderPage {
  let items: [CloudItem]
  let offset: Int
  let limit: Int
  let total: Int?
  let hasMore: Bool
  let servedFromCache: Bool
}

protocol CloudProvider {
  func validateCredentials() async throws
  func listFolder(id: String) async throws -> [CloudItem]
  func listFolderPage(
    id: String,
    offset: Int,
    limit: Int,
    forceRefresh: Bool
  ) async throws -> CloudFolderPage
  func videoSources(for item: CloudItem) async throws -> [VideoSource]
  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async
  func clearMountCache() async
}

extension CloudProvider {
  func listFolder(id: String) async throws -> [CloudItem] {
    let pageSize = 56
    var offset = 0
    var all: [CloudItem] = []

    while true {
      let page = try await listFolderPage(
        id: id,
        offset: offset,
        limit: pageSize,
        forceRefresh: false
      )
      all.append(contentsOf: page.items)
      guard page.hasMore else { break }
      offset += page.limit
    }
    return all
  }

  func clearMountCache() async {}
}

enum CloudProviderError: LocalizedError {
  case authenticationRequired(String)
  case network(String)
  case rateLimited(String)
  case remote(code: Int64, message: String)
  case invalidResponse(String)
  case responseChanged(endpoint: String)
  case missingOriginalURL
  case noPlayableSource

  var errorDescription: String? {
    switch self {
    case .authenticationRequired(let message):
      return message.isEmpty ? "媒体源登录信息已失效，请重新连接 OpenList / AList。" : message
    case .network(let message):
      return message.isEmpty ? "网络连接异常，请稍后重试。" : message
    case .rateLimited(let message):
      return message.isEmpty ? "媒体服务器当前繁忙，Cineva 已保留现有资料库缓存，请稍后继续浏览。" : message
    case .remote(let code, let message):
      return "媒体源错误（\(code)）：\(message.isEmpty ? "未知错误" : message)"
    case .invalidResponse(let endpoint):
      return "媒体服务器返回了无法识别的响应（\(endpoint)）。"
    case .responseChanged(let endpoint):
      return "媒体服务器返回的数据结构发生变化（\(endpoint)），Cineva 已保留可用数据。"
    case .missingOriginalURL:
      return "没有取得该视频的原画地址。"
    case .noPlayableSource:
      return "媒体源暂时没有返回可播放地址，请稍后重试。"
    }
  }

  var isAuthenticationFailure: Bool {
    if case .authenticationRequired = self { return true }
    return false
  }
}
