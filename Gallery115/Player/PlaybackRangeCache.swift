import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Per-playback byte cache for seekable original files. AVFoundation still owns
/// demuxing, decoding and presentation. All file/network/request state lives on
/// one serial queue; only a small byte-counter snapshot is shared with the UI.
final class PlaybackRangeCache: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
  private static let queue = DispatchQueue(label: "Cineva.playback-ranges", qos: .userInitiated)
  private static var cleanedOrphans = false // Access only on queue.
  private static let chunkSize: Int64 = 8 * 1_024 * 1_024
  private let originalURL: URL
  private let headers: [String: String]
  private let contentType: String
  private let directory: URL
  private let budget: Int64
  private var session: URLSession!
  private var requests: [AVAssetResourceLoadingRequest] = []
  private var fragments: [Fragment] = []
  private var activeTask: URLSessionDataTask?
  private var writer: FileHandle?
  private var activeFile: URL?
  private var activeStart: Int64 = 0
  private var activeEnd: Int64 = 0 // Exclusive requested end.
  private var received: Int64 = 0
  private var length: Int64?
  private var validator: String?
  private var validatorHeader: String?
  private var stopped = false
  private var consecutiveFailures = 0
  private let counterLock = NSLock()
  private var transferred: Int64 = 0
  private var retained: Int64 = 0

  private struct Fragment {
    let url: URL
    let start: Int64
    let count: Int64
    var touched: TimeInterval
    var end: Int64 { start + count }
  }

  static func supports(source: VideoSource, fileExtension: String) -> Bool {
    // Signed 115 originals are immutable for this playback session. Keep HLS,
    // WebDAV credentials, disc images and other engines on their existing path.
    source.isOriginal && source.id.hasPrefix("original-")
      && ["mp4", "mov", "m4v"].contains(fileExtension.lowercased())
      && ["https", "http"].contains(source.url.scheme?.lowercased() ?? "")
      && source.headers.keys.allSatisfy { $0.lowercased() == "user-agent" }
      && source.url.user == nil && source.url.password == nil
  }

  init?(source: VideoSource, fileExtension: String) {
    originalURL = source.url
    headers = source.headers
    contentType = UTType(filenameExtension: fileExtension)?.identifier ?? UTType.mpeg4Movie.identifier
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CinevaPlaybackRanges", isDirectory: true)
    directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let free = (try? FileManager.default.attributesOfFileSystem(forPath: root.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    // Leave headroom for the OS. No movie-sized allocation and no RAM mirror.
    budget = min(512 * 1_024 * 1_024, max(0, free - 512 * 1_024 * 1_024))
    guard budget >= 64 * 1_024 * 1_024 else { return nil }
    super.init()
    let created = Self.queue.sync { () -> Bool in
      do {
        if !Self.cleanedOrphans {
          // These are our disposable fragments from a previous app process.
          if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
          Self.cleanedOrphans = true
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return true
      } catch { return false }
    }
    guard created else { return nil }
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpMaximumConnectionsPerHost = 1
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 120
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = Self.queue
    session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
  }

  func makeAsset() -> AVURLAsset {
    // No credentials or remote URL are written into the custom URL or filenames.
    let url = URL(string: "cineva-range://\(UUID().uuidString)/video")!
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    asset.resourceLoader.setDelegate(self, queue: Self.queue)
    return asset
  }

  var counters: (network: Int64, disk: Int64) {
    counterLock.lock()
    defer { counterLock.unlock() }
    return (transferred, retained)
  }

  func stop() {
    Self.queue.async { self.finish(error: nil) }
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    guard !stopped else { return false }
    requests.append(loadingRequest)
    pump()
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    requests.removeAll { $0 === loadingRequest }
    pump()
  }

  private func pump() {
    guard !stopped else { return }
    var missing: Int64?
    var unfinished: [AVAssetResourceLoadingRequest] = []
    do {
      for request in requests where !request.isCancelled && !request.isFinished {
        if let length, let info = request.contentInformationRequest {
          info.contentType = contentType
          info.contentLength = length
          info.isByteRangeAccessSupported = true
        }
        guard let length else {
          unfinished.append(request)
          missing = missing ?? 0
          continue
        }
        guard let data = request.dataRequest else { request.finishLoading(); continue }
        guard data.requestedOffset >= 0, data.requestedLength >= 0 else { throw transportError() }
        let requestedEnd = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
        let end = data.requestsAllDataToEndOfResource || requestedEnd.overflow ? length
          : min(length, requestedEnd.partialValue)
        var offset = max(data.requestedOffset, data.currentOffset)
        while offset < end {
          guard let bytes = try cachedBytes(at: offset, count: Int(min(end - offset, 256 * 1_024))) else { break }
          data.respond(with: bytes)
          offset += Int64(bytes.count)
        }
        if offset >= end { request.finishLoading() }
        else {
          unfinished.append(request)
          // The newest demand wins after a seek; existing requests remain queued.
          missing = offset
        }
      }
      requests = unfinished
      guard let offset = missing else { return }
      if activeTask != nil && offset >= activeStart && offset < activeEnd { return }
      sealActiveFragment(cancel: true)
      startDownload(at: offset)
    } catch { finish(error: transportError()) }
  }

  private func cachedBytes(at offset: Int64, count: Int) throws -> Data? {
    let file: URL
    let start: Int64
    let available: Int64
    if let activeFile, offset >= activeStart, offset < activeStart + received {
      file = activeFile; start = activeStart; available = activeStart + received - offset
    } else if let index = fragments.firstIndex(where: { $0.start <= offset && offset < $0.end }) {
      fragments[index].touched = ProcessInfo.processInfo.systemUptime
      let fragment = fragments[index]
      file = fragment.url; start = fragment.start; available = fragment.end - offset
    } else { return nil }
    let reader = try FileHandle(forReadingFrom: file)
    defer { try? reader.close() }
    try reader.seek(toOffset: UInt64(offset - start))
    guard let bytes = try reader.read(upToCount: min(count, Int(available))), !bytes.isEmpty else { throw transportError() }
    return bytes
  }

  private func startDownload(at offset: Int64) {
    guard !stopped else { return }
    do {
      let total = length ?? Int64.max
      guard offset >= 0, offset < total else { throw transportError() }
      let end = offset + min(Self.chunkSize, total - offset)
      guard end > offset else { throw transportError() }
      evict(reserving: end - offset)
      let url = directory.appendingPathComponent(UUID().uuidString)
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw transportError() }
      writer = try FileHandle(forWritingTo: url)
      activeFile = url; activeStart = offset; activeEnd = end; received = 0
      var request = URLRequest(url: originalURL)
      for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
      request.setValue("bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
      let task = session.dataTask(with: request)
      activeTask = task
      task.resume()
    } catch { finish(error: transportError()) }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard !stopped, dataTask === activeTask, let response = response as? HTTPURLResponse,
      response.statusCode == 206,
      let rawRange = response.value(forHTTPHeaderField: "Content-Range"),
      let range = PlaybackHTTPRange.parse(rawRange), range.start == activeStart,
      range.end <= activeEnd, range.end == min(activeEnd, range.total),
      length == nil || length == range.total else {
      completionHandler(.cancel)
      if dataTask === activeTask { finish(error: transportError()) }
      return
    }
    if let validatorHeader, response.value(forHTTPHeaderField: validatorHeader) != validator {
      completionHandler(.cancel); finish(error: transportError()); return
    }
    if validator == nil {
      if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") {
        validator = etag; validatorHeader = "ETag"
      } else if let modified = response.value(forHTTPHeaderField: "Last-Modified") {
        validator = modified; validatorHeader = "Last-Modified"
      }
    }
    length = range.total
    activeEnd = range.end
    completionHandler(.allow)
    pump()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !stopped, dataTask === activeTask else { return }
    do {
      guard let writer, Int64(data.count) <= activeEnd - activeStart - received else { throw transportError() }
      try writer.write(contentsOf: data)
      received += Int64(data.count)
      counterLock.lock(); transferred += Int64(data.count); counterLock.unlock()
      pump() // Deliver arriving bytes immediately, not after an 8 MB download.
    } catch { finish(error: transportError()) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard !stopped, task === activeTask else { return }
    let complete = error == nil && activeStart + received == activeEnd
    sealActiveFragment(cancel: false)
    consecutiveFailures = complete ? 0 : consecutiveFailures + 1
    guard consecutiveFailures <= 1 else { finish(error: transportError()); return }
    // A dropped connection resumes at the first missing byte, keeping every
    // already received fragment. At most one retry, never an endless stall.
    pump()
  }

  private func sealActiveFragment(cancel: Bool) {
    if received > 0, activeStart + received == activeEnd { consecutiveFailures = 0 }
    let task = activeTask
    activeTask = nil // Ignore callbacks from a superseded request.
    if cancel { task?.cancel() }
    try? writer?.close()
    writer = nil
    if let file = activeFile {
      if received > 0 {
        fragments.append(Fragment(url: file, start: activeStart, count: received,
          touched: ProcessInfo.processInfo.systemUptime))
      } else { try? FileManager.default.removeItem(at: file) }
    }
    activeFile = nil; received = 0
    updateRetained()
  }

  private func evict(reserving bytes: Int64) {
    var total = fragments.reduce(Int64(0)) { $0 + $1.count }
    while total + bytes > budget, let oldest = fragments.indices.min(by: { fragments[$0].touched < fragments[$1].touched }) {
      let removed = fragments.remove(at: oldest)
      try? FileManager.default.removeItem(at: removed.url)
      total -= removed.count
    }
    updateRetained()
  }

  private func updateRetained() {
    let count = fragments.reduce(Int64(0)) { $0 + $1.count }
    counterLock.lock(); retained = count; counterLock.unlock()
  }

  private func transportError() -> NSError {
    NSError(domain: "CinevaPlaybackRangeCache", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "视频分段读取失败，正在切回直连。"])
  }

  private func finish(error: Error?) {
    guard !stopped else { return }
    stopped = true
    sealActiveFragment(cancel: true)
    session.invalidateAndCancel() // Break URLSession's strong delegate ownership.
    for request in requests where !request.isCancelled && !request.isFinished {
      request.finishLoading(with: error ?? URLError(.cancelled))
    }
    requests.removeAll(); fragments.removeAll()
    try? FileManager.default.removeItem(at: directory)
    updateRetained()
  }
}

/// Content-Range has an inclusive wire end; everything inside the cache uses an
/// exclusive end. Reject malformed, wildcard and overflowing server responses.
enum PlaybackHTTPRange {
  static func parse(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
    let fields = value.lowercased().split(separator: " ")
    guard fields.count == 2, fields[0] == "bytes" else { return nil }
    let pair = fields[1].split(separator: "/", omittingEmptySubsequences: false)
    guard pair.count == 2, let total = Int64(pair[1]), total > 0 else { return nil }
    let bounds = pair[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, let start = Int64(bounds[0]), let last = Int64(bounds[1]),
      start >= 0, last >= start, last < total else { return nil }
    return (start, last + 1, total)
  }
}
