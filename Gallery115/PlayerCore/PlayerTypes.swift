import Foundation
import CoreGraphics

enum PlayerState: Equatable, Sendable {
  case idle, preparing, buffering, playing, paused, seeking, ended, stopped
  case failed(String)

  var title: String {
    switch self {
    case .idle: return "未开始"
    case .preparing: return "准备播放"
    case .buffering: return "正在缓冲"
    case .playing: return "正在播放"
    case .paused: return "已暂停"
    case .seeking: return "正在定位"
    case .ended: return "播放结束"
    case .stopped: return "已停止"
    case .failed: return "播放失败"
    }
  }

  var needsLoadingIndicator: Bool {
    self == .preparing || self == .buffering
  }
}

enum PlayerBackend: String, Sendable {
  case apple = "AVPlayer"
  case vlc = "VLC"
}

struct PlayerTrack: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable { case audio, subtitle }
  let id: String
  let title: String
  let kind: Kind
  let language: String?
}

struct PlayerChapter: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let start: Double
  let end: Double
}

struct SubtitleCue: Identifiable, Hashable, Sendable {
  let id: Int
  let start: Double
  let end: Double
  let text: String
}

/// nil means unavailable, not zero or a claim of hardware/HDR support.
/// Downloaded bytes and resident cache bytes are deliberately separate.
struct PlayerStatistics: Sendable {
  var backend: PlayerBackend?
  var codec: String?
  var videoSize: CGSize?
  var fps: Double?
  var hdrFormat: String?
  var networkMbps: Double?
  var downloadedBytes: Int64?
  var bufferedSeconds: Double?
  var cachedBytes: Int64?
  var decoder: String?
  var renderer: String?
  var droppedFrames: Int?
  var avSyncOffset: Double?
}

/// Identity restarts feedback timing when a newer seek supersedes an old one.
struct PlayerLoadingFeedback: Equatable, Sendable {
  let delayMilliseconds: Int
  let generation: Int
}
