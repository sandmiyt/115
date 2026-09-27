import Foundation

/// Every new media item starts here. Legacy engine preferences cannot change it.
enum PlaybackPolicy {
  static func input(for source: VideoSource) -> FFmpegInputBackend {
    source.isOriginal && source.url.pathExtension.lowercased() != "m3u8" ? .customAVIOCached : .ffmpegHTTP
  }
  static func migrateEnginePreference(_ defaults: UserDefaults) {
    defaults.removeObject(forKey:"cineva.playback.originalEngine.v1")
  }
  static func timestamp(_ seconds:Double) -> String {
    let safe=seconds.isFinite ? min(max(0,seconds),Double(Int64.max/2000)) : 0
    let ms=Int64((safe*1000).rounded()), total=ms/1000
    if total>=3600 { return String(format:"%02lld:%02lld:%02lld.%03lld",total/3600,total/60%60,total%60,ms%1000) }
    return String(format:"%02lld:%02lld.%03lld",total/60,total%60,ms%1000)
  }
}
enum FFmpegInputBackend:String,Sendable { case ffmpegHTTP, customAVIODirect, customAVIOCached }

struct FFmpegFailureSnapshot: Sendable {
  let session: UUID
  let generation: Int32
  let backend: FFmpegInputBackend
  let build: String
  let stage: String
  let nativeError: Int32
  let transport: String
  let operations: String
  var text: String {
    "Cineva \(build) · FFmpeg failure (frozen before teardown)\n"
    + "session=\(session.uuidString) · generation=\(generation) · backend=\(backend.rawValue)\n"
    + "stage=\(stage) · FFmpeg=\(nativeError)\n" + transport + "\n" + operations
  }
  static func stageName(_ value: Int32) -> String {
    switch value {
    case 1:return "打开媒体"
    case 2:return "探测流信息"
    case 3:return "选择视频轨"
    case 4:return "打开视频解码器"
    case 5:return "打开音频解码器"
    case 6:return "定位媒体"
    case 7:return "读取媒体包"
    case 8:return "视频解码"
    case 9:return "音频解码"
    case 10:return "视频表面输出"
    case 11:return "启动工作线程"
    default:return "引擎控制 / 尚无原生失败阶段"
    }
  }
}

/// Entry timestamp only; no persistent media or credential data.
@MainActor enum PlaybackLaunchClock {
  private static var pending:(String,Double)?
  static func mark(_ id:String) { pending=(id,ProcessInfo.processInfo.systemUptime) }
  static func take(_ id:String) -> Double? {
    guard let value=pending, value.0==id else { return nil }
    pending=nil; return value.1
  }
}
