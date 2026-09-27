import Foundation
import CryptoKit

struct RangeCacheIdentity: Sendable {
  let account: String
  let fileID: String
  let size: Int64
  let validator: String
  var key: String {
    let fields = [account, fileID, String(size), validator]
    let encoded = fields.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct RangeStatistics: Sendable {
  var requests = 0, responses200 = 0, responses206 = 0, responses416 = 0
  var networkBytes: Int64 = 0, memoryHitBytes: Int64 = 0, diskHitBytes: Int64 = 0
  var misses = 0, coalesced = 0, cancelled = 0, refreshes = 0
  var memoryBytes = 0
  var lastError: String?
}

/// Disk operations are serialized independently of network callbacks and never
/// hold the coordinator condition. Only verified complete pages are persisted.
final class SegmentDiskCache: @unchecked Sendable {
  static let shared = SegmentDiskCache()
  private let queue = DispatchQueue(label: "cineva.segment.disk", qos: .utility)
  private let limit: Int64 = 512 * 1024 * 1024
  private let root: URL
  private var entries: [URL:(Int64,Date)] = [:]
  private var indexed = false
  private func indexIfNeeded() {
    guard !indexed else { return }; indexed=true
    let files=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []
    for file in files {
      if let v=try? file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) {
        entries[file]=(Int64(v.fileSize ?? 0),v.contentModificationDate ?? .distantPast)
      }
    }
  }
  init(root: URL? = nil) {
    self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("CinevaSegments-v1", isDirectory: true)
  }
  private func path(_ key: String, _ offset: Int64) -> URL { root.appendingPathComponent("\(key)-\(offset).block") }
  func read(key: String, offset: Int64, length: Int) -> Data? {
    queue.sync {
      indexIfNeeded()
      let file = path(key, offset)
      guard let stored = try? Data(contentsOf: file), stored.count == length+32 else { return nil }
      let data=stored.dropFirst(32)
      guard Data(SHA256.hash(data:data))==stored.prefix(32) else {
        try? FileManager.default.removeItem(at:file); entries.removeValue(forKey:file); return nil
      }
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      entries[file]=(Int64(stored.count),Date())
      return Data(data)
    }
  }
  func write(_ data: Data, key: String, offset: Int64) {
    // Serial backpressure prevents unlimited pending page copies in the disk queue.
    queue.sync {
      let fm = FileManager.default
      indexIfNeeded()
      try? fm.createDirectory(at: root, withIntermediateDirectories: true)
      var excluded = root
      var values = URLResourceValues(); values.isExcludedFromBackup = true
      try? excluded.setResourceValues(values)
      let file=path(key,offset), stored=Data(SHA256.hash(data:data))+data
      guard (try? stored.write(to:file,options:.atomic)) != nil else { return }
      entries[file]=(Int64(stored.count),Date())
      var total=entries.values.reduce(Int64(0)) { $0+$1.0 }
      if total>limit {
        for entry in entries.sorted(by: { $0.value.1<$1.value.1 }) where total>limit {
          if (try? fm.removeItem(at:entry.key)) != nil { total-=entry.value.0; entries.removeValue(forKey:entry.key) }
        }
      }
    }
  }
  func clear() { queue.sync { try? FileManager.default.removeItem(at: root); entries.removeAll(); indexed=false } }
}

/// Synchronous AVIO callers wait only on a dedicated demux worker. URLSession's
/// serial delegate queue progresses independently of MainActor and that worker.
/// A 1 MiB transfer window is delivered incrementally in <=64 KiB reads; it is
/// not a minimum download prerequisite for the first frame.
final class RangeCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias Refresh = @Sendable () async throws -> VideoSource
  private final class Flight {
    let start: Int64, end: Int64, generation: Int32
    var data = Data()
    var expected = 0
    var accepted = false
    var finished = false
    var error: Int32 = 0
    var task: URLSessionDataTask?
    var redirects = 0
    init(start: Int64, end: Int64, generation: Int32) {
      self.start = start; self.end = end; self.generation = generation
    }
  }
  private let condition = NSCondition()
  private let page: Int64 = 65536
  private let window: Int64 = 1048576
  private let memoryLimit = 32 * 1024 * 1024
  private let identity: RangeCacheIdentity
  private let disk: SegmentDiskCache
  private let persistent: Bool
  private let refresh: Refresh?
  private var source: VideoSource
  private var length: Int64
  private var generation: Int32 = 1
  private var closed = false
  private var refreshing = false
  private var refreshed = false
  private var responseValidator: String?
  private var flights: [Int: Flight] = [:]
  private var memory: [Int64: Data] = [:]
  private var order: [Int64] = []
  private var stats = RangeStatistics()
  private var session: URLSession!

  init(source: VideoSource, identity: RangeCacheIdentity, disk: SegmentDiskCache = .shared,
       refresh: Refresh? = nil) {
    self.source = source; self.identity = identity; self.disk = disk; self.refresh = refresh
    length = identity.size > 0 ? identity.size : -1
    persistent = !identity.validator.isEmpty && identity.size > 0
    super.init()
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil; config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 12
    config.httpMaximumConnectionsPerHost = 2
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }
  var statistics: RangeStatistics {
    condition.lock(); defer { condition.unlock() }; return stats
  }
  var fileSize: Int64 {
    condition.lock(); defer { condition.unlock() }; return length
  }
  func changeGeneration(_ value: Int32) {
    condition.lock()
    generation = value
    if value < 0 { closed = true }
    let tasks = flights.values.compactMap(\.task)
    stats.cancelled += tasks.count
    flights.removeAll()
    condition.broadcast(); condition.unlock()
    tasks.forEach { $0.cancel() }
    if value < 0 { session.invalidateAndCancel() }
  }
  func close() { changeGeneration(-1) }

  /// Returns bytes, 0 only at verified EOF, or negative errno-like transport
  /// outcomes: -1 IO/protocol, -2 timeout, -3 cancellation, -4 source changed.
  func read(offset: Int64, buffer: UnsafeMutablePointer<UInt8>, count: Int, generation wanted: Int32) -> Int32 {
    guard offset >= 0, count > 0 else { return -1 }
    let base = offset / page * page
    let deadline = Date().addingTimeInterval(12)
    var attempts = 0
    var checkedDisk = false
    condition.lock()
    defer { condition.unlock() }
    while true {
      if closed || wanted != generation { return -3 }
      if length >= 0, offset >= length { return 0 }
      if let data = memory[base], Int(offset - base) < data.count {
        let start = Int(offset - base), n = min(count, data.count - start)
        data.copyBytes(to: buffer, from: start..<(start+n))
        stats.memoryHitBytes += Int64(n)
        order.removeAll { $0 == base }; order.append(base)
        return Int32(n)
      }
      if !checkedDisk, persistent, length > 0 {
        checkedDisk = true
        let expected = Int(min(page, length - base))
        condition.unlock()
        let cached = disk.read(key: identity.key, offset: base, length: expected)
        condition.lock()
        if let cached, !closed, wanted == generation {
          insert(cached, at: base)
          let start = Int(offset-base), n = min(count, cached.count-start)
          cached.copyBytes(to: buffer, from: start..<(start+n))
          stats.diskHitBytes += Int64(n)
          return Int32(n)
        }
        continue
      }
      if Date() >= deadline { stats.lastError = "Range 读取超时"; return -2 }
      if let flight = flights.values.first(where: { $0.start <= offset && offset <= $0.end }) {
        let start = Int(offset - flight.start)
        if flight.accepted, start < flight.data.count {
          let n = min(count, flight.data.count-start)
          flight.data.copyBytes(to: buffer, from: start..<(start+n))
          return Int32(n)
        }
        if flight.finished {
          let error = flight.error
          if let id = flight.task?.taskIdentifier { flights.removeValue(forKey: id) }
          if error == -4 { return error }
          if error == -5, !refreshed, let refresh {
            refreshed = true; refreshing = true; stats.refreshes += 1
            Task.detached { [weak self] in
              do { let source = try await refresh(); self?.didRefresh(source) }
              catch { self?.didRefresh(nil) }
            }
          } else {
            attempts += 1
            if attempts >= 2 || error == -5 || error == -6 { return error == -2 ? -2 : -1 }
          }
          continue
        }
        stats.coalesced += 1
      } else if !refreshing {
        // Prioritize this demand. Only two active transfer windows are retained.
        if flights.count >= 2, let old = flights.values.first(where: { $0.finished }) {
          if let id = old.task?.taskIdentifier { flights.removeValue(forKey: id) }
        }
        if flights.count < 2 { startFlight(at: base, generation: wanted) }
      }
      _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
    }
  }
  private func insert(_ data: Data, at offset: Int64) {
    stats.memoryBytes -= memory[offset]?.count ?? 0
    memory[offset] = data; stats.memoryBytes += data.count
    order.removeAll { $0 == offset }; order.append(offset)
    while stats.memoryBytes > memoryLimit, let first = order.first {
      stats.memoryBytes -= memory.removeValue(forKey: first)?.count ?? 0
      order.removeFirst()
    }
  }
  private func startFlight(at start: Int64, generation: Int32) {
    let end = min(start / window * window + window - 1, length > 0 ? length - 1 : Int64.max)
    let flight = Flight(start: start, end: end, generation: generation)
    var request = URLRequest(url: source.url)
    for (key, value) in source.headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let responseValidator { request.setValue(responseValidator, forHTTPHeaderField: "If-Range") }
    let task = session.dataTask(with: request); flight.task = task
    flights[task.taskIdentifier] = flight
    stats.requests += 1; stats.misses += 1
    task.resume()
  }
  private func didRefresh(_ newSource: VideoSource?) {
    condition.lock(); defer { condition.broadcast(); condition.unlock() }
    refreshing = false
    if let newSource, newSource.isOriginal == source.isOriginal { source = newSource }
    else { closed = true; stats.lastError = "播放地址刷新失败" }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    condition.lock()
    guard let f = flights[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
      condition.unlock(); completionHandler(.cancel); return
    }
    switch http.statusCode {
    case 200: stats.responses200 += 1
    case 206: stats.responses206 += 1
    case 416: stats.responses416 += 1
    default: break
    }
    var valid = false
    if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
      let parsed = Self.contentRange(range), parsed.start == f.start, parsed.end == min(f.end,parsed.total-1),
      (length < 0 || length == parsed.total), parsed.end >= parsed.start,
      http.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true {
      let validator = http.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
      if let prior = responseValidator, let validator, prior != validator { f.error = -4 }
      else {
        if responseValidator == nil { responseValidator = validator }
        length = parsed.total; f.expected = Int(parsed.end-parsed.start+1)
        valid = http.expectedContentLength < 0 || http.expectedContentLength == Int64(f.expected)
      }
    }
    if http.statusCode==200, f.start==0, http.expectedContentLength>0,
      http.expectedContentLength<=window, length<0 || length==http.expectedContentLength {
      length=http.expectedContentLength; f.expected=Int(length); valid=true
    }
    if http.statusCode==416, let range=http.value(forHTTPHeaderField:"Content-Range"),
      range.hasPrefix("bytes */"), let total=Int64(range.dropFirst(8)), total>=0,
      f.start>=total, length<0 || length==total {
      length=total; f.expected=0; f.finished=true; valid=true
    }
    // A server ignoring Range must never write offset-zero bytes at a nonzero
    // cache offset. 416 is not EOF unless size and requested offset prove it.
    if !valid {
      f.error = f.error == -4 ? -4 : ([401,403].contains(http.statusCode) ? -5 : -6)
      f.finished = true
      stats.lastError = "HTTP \(http.statusCode)：Range / 长度 / 版本校验失败"
      condition.broadcast()
    }
    f.accepted = valid
    condition.unlock(); completionHandler(valid ? .allow : .cancel)
  }
  static func contentRange(_ text: String) -> (start: Int64, end: Int64, total: Int64)? {
    guard text.hasPrefix("bytes ") else { return nil }
    let parts = text.dropFirst(6).split(separator: "/")
    guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
    let span = parts[0].split(separator: "-")
    guard span.count == 2, let start = Int64(span[0]), let end = Int64(span[1]),
      start >= 0, end >= start, end < total else { return nil }
    return (start,end,total)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    condition.lock()
    stats.networkBytes += Int64(data.count)
    guard let f = flights[dataTask.taskIdentifier], f.accepted, !f.finished else { condition.unlock(); return }
    guard f.data.count + data.count <= f.expected else {
      f.error = -6; f.finished = true; stats.lastError = "Range 响应超出声明长度"
      condition.broadcast(); condition.unlock(); dataTask.cancel(); return
    }
    f.data.append(data)
    condition.broadcast(); condition.unlock()
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    condition.lock()
    guard let f = flights[task.taskIdentifier] else { condition.unlock(); return }
    if !f.finished {
      f.finished = true
      if error != nil || !f.accepted || f.data.count != f.expected {
        f.error = (error as NSError?)?.code == NSURLErrorTimedOut ? -2 : -1
        stats.lastError = "Range 请求中断或响应长度不足"
      }
    }
    var pages: [(Int64,Data)] = []
    if f.error == 0, f.accepted {
      var offset = 0
      while offset < f.data.count {
        let end = min(offset+Int(page),f.data.count)
        let part = f.data.subdata(in: offset..<end)
        if part.count == Int(page) || f.start+Int64(end) == length {
          insert(part, at: f.start+Int64(offset)); pages.append((f.start+Int64(offset),part))
        }
        offset = end
      }
    }
    condition.broadcast(); condition.unlock()
    if persistent { for (offset,data) in pages { disk.write(data, key: identity.key, offset: offset) } }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    condition.lock()
    guard let flight = flights[task.taskIdentifier] else { condition.unlock(); completionHandler(nil); return }
    flight.redirects += 1
    let previous = response.url, next = request.url
    guard flight.redirects <= 5, next?.scheme == "https" || (previous?.scheme == "http" && next?.scheme == "http") else {
      condition.unlock(); completionHandler(nil); return
    }
    var redirected = request
    if previous?.host != next?.host || previous?.port != next?.port || previous?.scheme != next?.scheme {
      // Rebuild cross-origin headers: do not forward custom credentials either.
      redirected.allHTTPHeaderFields = [:]
      redirected.setValue("bytes=\(flight.start)-\(flight.end)", forHTTPHeaderField: "Range")
      redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }
    stats.requests += 1
    condition.unlock(); completionHandler(redirected)
  }
}
