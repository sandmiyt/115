import Foundation
import CinevaFFmpeg

/// Dependency capabilities only. Actual Phase 3 demux/decode is implemented in
/// FFmpegDecodeSession, independently of AVPlayer and VLC.
enum FFmpegRuntime {
  struct BuildInfo {
    let version: String
    let license: String
    let configuration: String
    let allocationCheckPassed: Bool
    let decoders: [String]
    let videoToolboxConfigurations: [String]
    let demuxers: [String]
  }

  static let buildInfo: BuildInfo = {
    let names = ["h264", "hevc", "vp8", "vp9", "av1", "mpeg2video", "mpeg4",
                 "aac", "mp3", "flac", "alac", "ac3", "eac3", "opus", "vorbis"]
    let formats = ["mov", "matroska", "mpegts", "flv", "avi", "mp3", "aac", "flac"]
    return BuildInfo(
      version: String(cString: CinevaFFmpegVersion()),
      license: String(cString: CinevaFFmpegLicense()),
      configuration: String(cString: CinevaFFmpegConfiguration()),
      allocationCheckPassed: CinevaFFmpegRuntimeCheck() == 1,
      decoders: names.filter { name in name.withCString { CinevaFFmpegHasDecoder($0) == 1 } },
      videoToolboxConfigurations: names.filter { name in name.withCString { CinevaFFmpegHasVideoToolbox($0) == 1 } },
      demuxers: formats.filter { name in name.withCString { CinevaFFmpegHasDemuxer($0) == 1 } }
    )
  }()

  static var licenseText: String {
    guard let bundle = Bundle(identifier: "com.cineva.ffmpeg"),
      let url = bundle.url(forResource: "FFmpeg-LICENSE", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8) else {
      return "许可文本随 CinevaFFmpeg.framework 分发；完整许可也可在 ffmpeg.org/legal.html 查看。"
    }
    return text
  }
}
