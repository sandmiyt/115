import AVFoundation
import CinevaFFmpeg
import Observation
import UIKit

/// Owns one native session. Cancellation is immediate; joining workers and
/// freeing FFmpeg objects never blocks SwiftUI or a display-link callback.
final class FFmpegSessionHandle: @unchecked Sendable {
  let pointer: OpaquePointer
  let io: RangeCoordinator?
  let previewReader:FFmpegPreviewReader?
  init(_ pointer: OpaquePointer, io: RangeCoordinator? = nil, previewReader:FFmpegPreviewReader? = nil) { self.pointer = pointer; self.io = io; self.previewReader=previewReader }
  deinit {
    CinevaFFmpegSessionCancel(pointer)
    let address = UInt(bitPattern: pointer)
    let retainedIO = io
    let retainedReader=previewReader
    DispatchQueue.global(qos: .utility).async {
      if let pointer = OpaquePointer(bitPattern: address) { CinevaFFmpegSessionDestroy(pointer) }
      withExtendedLifetime(retainedIO) {}
      withExtendedLifetime(retainedReader) {}
    }
  }
}

