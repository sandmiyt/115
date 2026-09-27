import CinevaFFmpeg
import Foundation

extension CinevaFFmpegSessionOptions {
  mutating func attach(_ coordinator: RangeCoordinator) {
    ioContext = Unmanaged.passUnretained(coordinator).toOpaque()
    read = { context, offset, buffer, count, generation in
      Unmanaged<RangeCoordinator>.fromOpaque(context).takeUnretainedValue()
        .read(offset: offset, buffer: buffer, count: Int(count), generation: generation)
    }
    size = { context in Unmanaged<RangeCoordinator>.fromOpaque(context).takeUnretainedValue().fileSize }
    cancelIO = { context, generation in
      Unmanaged<RangeCoordinator>.fromOpaque(context).takeUnretainedValue().changeGeneration(generation)
    }
  }
}
