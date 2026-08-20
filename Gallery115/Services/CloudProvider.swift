import Foundation

protocol CloudProvider {
  func validateCredentials() async throws
  func listFolder(id: String) async throws -> [CloudItem]
  func videoSources(for item: CloudItem) async throws -> [VideoSource]
  func updateVideoHistory(pickCode: String, seconds: Int, watchEnd: Bool) async
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
      return message.isEmpty ? "115 登录状态已失效，请重新连接 115 网盘。" : message
    case .network(let message):
      return message.isEmpty ? "网络连接异常，请稍后重试。" : message
    case .rateLimited(let message):
      return message.isEmpty ? "115 请求过于频繁，Cineva 已暂停片刻，请稍后再试。" : message
    case .remote(let code, let message):
      return "115 接口错误（\(code)）：\(message.isEmpty ? "未知错误" : message)"
    case .invalidResponse(let endpoint):
      return "115 返回了无法识别的响应（\(endpoint)）。"
    case .responseChanged(let endpoint):
      return "115 返回的数据结构发生变化（\(endpoint)），Cineva 已阻止异常数据继续影响播放。"
    case .missingOriginalURL:
      return "没有取得该视频的原画地址。"
    case .noPlayableSource:
      return "115 暂时没有返回可播放地址，请稍后重试。"
    }
  }
}
