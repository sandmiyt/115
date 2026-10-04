import CinevaFFmpeg
import Foundation

/// Coordinates a retained preview session's timeout budget with its AVIO gate.
/// Calls are synchronous so an old drag cannot pause a newly started drag.
final class FFmpegPreviewActivity: @unchecked Sendable {
  private let coordinator: RangeCoordinator?
  private let lock = NSLock()
  private var active = true
  private var handle: FFmpegSessionHandle?
  init(coordinator: RangeCoordinator? = nil) { self.coordinator = coordinator }
  func setActive(_ active: Bool) {
    lock.lock(); defer { lock.unlock() }
    self.active = active
    if let handle { CinevaFFmpegSessionSetPreviewIOActive(handle.pointer, active ? 1 : 0) }
    // Resume the native budget before waking any previously gated AVIO read.
    coordinator?.setPreviewReadsAllowed(active)
  }
  func attach(_ handle: FFmpegSessionHandle?) {
    lock.lock(); defer { lock.unlock() }
    self.handle = handle
    if let handle { CinevaFFmpegSessionSetPreviewIOActive(handle.pointer, active ? 1 : 0) }
  }
}

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

/// One AVIO cursor's cancellation scope. Never calls coordinator.close().
final class FFmpegPreviewReader: @unchecked Sendable {
  let coordinator:RangeCoordinator
  private let lock=NSLock()
  private var token:Int32
  private var generation:Int32=1
  init(_ coordinator:RangeCoordinator) { self.coordinator=coordinator; token=coordinator.makePreviewToken() }
  func read(offset:Int64,buffer:UnsafeMutablePointer<UInt8>,count:Int,generation wanted:Int32) -> Int32 {
    lock.lock(); let current=token, valid=generation==wanted; lock.unlock()
    guard valid else { return -3 }
    return coordinator.read(offset:offset,buffer:buffer,count:count,generation:current)
  }
  func cancel(_ next:Int32) {
    lock.lock(); let old=token
    generation=next; token=next<0 ? -1 : coordinator.makePreviewToken(); lock.unlock()
    coordinator.cancelPreview(old)
  }
  deinit { coordinator.cancelPreview(token) }
}
extension CinevaFFmpegSessionOptions {
  mutating func attachPreview(_ reader:FFmpegPreviewReader) {
    ioContext=Unmanaged.passUnretained(reader).toOpaque()
    read={ context,offset,buffer,count,generation in
      Unmanaged<FFmpegPreviewReader>.fromOpaque(context).takeUnretainedValue()
        .read(offset:offset,buffer:buffer,count:Int(count),generation:generation)
    }
    size={ context in Unmanaged<FFmpegPreviewReader>.fromOpaque(context).takeUnretainedValue().coordinator.fileSize }
    cancelIO={ context,generation in Unmanaged<FFmpegPreviewReader>.fromOpaque(context).takeUnretainedValue().cancel(generation) }
  }
}
