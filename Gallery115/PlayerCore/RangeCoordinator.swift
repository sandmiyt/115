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

enum RangeFailureKind: String, Sendable {
  case cancelled, timeout, authentication, unsupportedBackend, malformedResponse
  case metadataConflict, resourceChanged, network, redirectPolicy
  case serverError, rateLimited, httpStatus
}

/// Only allowlisted numeric/protocol facts cross the diagnostic boundary.
/// No URL, request headers, server free text, ETag or NSError.userInfo is retained.
struct RangeFailureEvidence: Sendable {
  let kind: RangeFailureKind
  let generation: Int32
  let status: Int
  let requestedStart: Int64, requestedEnd: Int64
  let contentRange: String
  let declaredBytes: Int64, receivedBytes: Int
  let hintedLength: Int64, verifiedLength: Int64, observedLength: Int64
  let redirects: Int
  let applicationUAPreserved: Bool
  let networkDomain: String
  let networkCode: Int
  var text: String {
    "transport=\(kind.rawValue) · generation=\(generation) · HTTP=\(status)\n"
    + "request=\(requestedStart)-\(requestedEnd) · Content-Range=\(contentRange)\n"
    + "declared=\(declaredBytes) · received=\(receivedBytes) · hint=\(hintedLength) · verified=\(verifiedLength) · observed=\(observedLength)\n"
    + "redirects=\(redirects) · application-UA-preserved=\(applicationUAPreserved) · network=\(networkDomain)/\(networkCode)"
  }
}

struct RangeAttempt: Sendable {
  let number: Int
  let offset: Int64
  var status = 0
  var plannedWait = 0.0
  var actualWait = 0.0
  var retryAfter: Double?
}
struct RangeRecoveryReport: Sendable {
  let generation: Int32
  let outcome: String
  let elapsed: Double
  let reason: String
  let attempts: [RangeAttempt]
  var text: String {
    "HTTP recovery=\(outcome) · generation=\(generation) · attempts=\(attempts.count)/3 · elapsed=\(String(format: "%.3f",elapsed)) s · reason=\(reason)\n"
    + attempts.map { "#\($0.number) status=\($0.status) offset=\($0.offset) Retry-After=\($0.retryAfter.map { String(format:"%.3f",$0) } ?? "none") wait=\(String(format:"%.3f/%.3f",$0.actualWait,$0.plannedWait)) s" }.joined(separator:"; ")
  }
}

struct RangeStatistics: Sendable {
  var requests = 0, responses200 = 0, responses206 = 0, responses416 = 0
  var networkBytes: Int64 = 0, memoryHitBytes: Int64 = 0, diskHitBytes: Int64 = 0
  var misses = 0, coalesced = 0, cancelled = 0, refreshes = 0
  var memoryBytes = 0
  var lastError: String?
  var lastIssue: RangeFailureEvidence?
  var terminalFailure: RangeFailureEvidence?
  var lastReadOffset: Int64 = -1
  var lastReadCount = 0
  var lastReadResult: Int32 = 0
  var hintedLength: Int64 = -1, verifiedLength: Int64 = -1
  var clues: [String] = []
  var recovery: RangeRecoveryReport?
  var recovered = 0, exhausted = 0, recoveryCancelled = 0
  var recoveryText: String { recovery?.text ?? "HTTP recovery: none" }
  var text: String {
    ((terminalFailure ?? lastIssue)?.text ?? "transport: no current failure") + "\n" + recoveryText
  }
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
  private var revision: UInt64 = 0
  var epoch: UInt64 { queue.sync { revision } }
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
  func write(_ data: Data, key: String, offset: Int64, epoch: UInt64) {
    // Serial backpressure prevents unlimited pending page copies in the disk queue.
    queue.sync {
      guard epoch == revision else { return }
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
  func clear() { queue.sync {
    revision &+= 1
    try? FileManager.default.removeItem(at: root); entries.removeAll(); indexed=false
  } }
}

/// Synchronous AVIO callers wait only on a dedicated demux worker. URLSession's
/// serial delegate queue progresses independently of MainActor and that worker.
/// A 1 MiB transfer window is delivered incrementally in <=64 KiB reads; it is
/// not a minimum download prerequisite for the first frame.
final class RangeCoordinator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias Refresh = @Sendable () async throws -> VideoSource
  private final class Recovery {
    let id=UUID(), started=ProcessInfo.processInfo.systemUptime
    let generation:Int32
    var attempts:[RangeAttempt]=[]
    var hadFailure=false
    var outcome="recovering"
    var reason="none"
    init(generation:Int32) { self.generation=generation }
  }
  private final class Flight {
    let start: Int64, end: Int64, generation: Int32
    var data = Data()
    var expected = 0
    var receivedBytes = 0
    var receivedEnd: Int64 = -1
    var consumedThrough: Int64
    var accepted = false, finished = false
    var error: Int32 = 0
    var task: URLSessionDataTask?
    var redirects = 0, status = 0
    var contentRange = "unavailable"
    var observedLength: Int64 = -1, declaredBytes: Int64 = -1
    var uaPreserved = true
    var issue: RangeFailureEvidence?
    let recovery: Recovery
    let attemptIndex: Int
    var retryAfter: Double?
    var retryPending=false
    var readers:Set<Int32>=[]
    init(start: Int64, end: Int64, generation: Int32, recovery: Recovery? = nil) {
      self.start=start; self.end=end; self.generation=generation; consumedThrough=start; readers=[generation]
      self.recovery=recovery ?? Recovery(generation:generation)
      attemptIndex=self.recovery.attempts.count
      self.recovery.attempts.append(RangeAttempt(number:attemptIndex+1,offset:start))
    }
  }
  private struct Page {
    var data = Data(repeating:0,count:65536)
    var coverage: [Range<Int>] = []
    mutating func append(_ bytes: Data, at offset: Int) {
      data.replaceSubrange(offset..<(offset+bytes.count),with:bytes)
      let sorted=(coverage+[offset..<(offset+bytes.count)]).sorted { $0.lowerBound<$1.lowerBound }
      coverage=[]
      for span in sorted {
        if let previous=coverage.last, span.lowerBound<=previous.upperBound {
          coverage[coverage.count-1]=previous.lowerBound..<max(previous.upperBound,span.upperBound)
        } else { coverage.append(span) }
      }
    }
    func available(at offset: Int) -> Int {
      coverage.first(where: { $0.contains(offset) }).map { $0.upperBound-offset } ?? 0
    }
  }
  private let condition=NSCondition()
  private let page:Int64=65536, window:Int64=1048576
  private let memoryLimit=32*1024*1024
  private let identity: RangeCacheIdentity
  private let disk: SegmentDiskCache
  private let diskEpoch: UInt64
  private let cacheEnabled: Bool
  private let refresh: Refresh?
  private var source: VideoSource
  private var length:Int64 = -1 // HTTP-confirmed only, never the listing hint.
  private var generation:Int32 = 1
  private var previewTokens:Set<Int32>=[]
  private var nextPreviewToken:Int32=1_000_000
  private var readerErrors:[Int32:Int32]=[:]
  private var primaryReaders=0
  private var closed=false, refreshing=false, refreshed=false
  private var fatalError:Int32?
  private var responseValidator:String?
  private var flights:[Int:Flight]=[:]
  private var memory:[Int64:Page]=[:]
  private var order:[Int64]=[]
  private var stats=RangeStatistics()
  private var session:URLSession!
  private var issueOwner:UUID?
  private var refreshTask:Task<Void,Never>?
  private var refreshOwner:Int32?
  // A new schema prevents reuse of v53 pages whose HTTP representation was not checked.
  private var diskKey:String? {
    guard cacheEnabled, length>0, !identity.validator.isEmpty, let responseValidator else { return nil }
    return RangeCacheIdentity(account:identity.account,fileID:identity.fileID,size:length,
      validator:"http-v2:"+identity.validator+":"+responseValidator).key
  }
  init(source: VideoSource, identity: RangeCacheIdentity, disk: SegmentDiskCache = .shared,
       cacheEnabled: Bool = true, refresh: Refresh? = nil) {
    self.source=source; self.identity=identity; self.disk=disk; self.refresh=refresh
    self.cacheEnabled=cacheEnabled; diskEpoch=disk.epoch; stats.hintedLength=identity.size
    super.init()
    let config=URLSessionConfiguration.ephemeral
    config.urlCache=nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage=nil; config.httpShouldSetCookies=false
    config.timeoutIntervalForRequest=5; config.timeoutIntervalForResource=12
    config.httpMaximumConnectionsPerHost=2
    let queue=OperationQueue(); queue.maxConcurrentOperationCount=1; queue.qualityOfService = .userInitiated
    session=URLSession(configuration:config,delegate:self,delegateQueue:queue)
  }
  var statistics:RangeStatistics { condition.lock(); defer { condition.unlock() }; return stats }
  var fileSize:Int64 { condition.lock(); defer { condition.unlock() }; return length }
  // Preview scopes share verified pages, validators, URL refresh and the same
  // two-request budget, but never the primary cursor or cancellation lifetime.
  func makePreviewToken() -> Int32 {
    condition.lock(); defer { condition.unlock() }
    nextPreviewToken += 1; previewTokens.insert(nextPreviewToken); return nextPreviewToken
  }
  private func valid(_ token:Int32) -> Bool { !closed && (token==generation || previewTokens.contains(token)) }
  func cancelPreview(_ token:Int32) {
    condition.lock(); previewTokens.remove(token); readerErrors.removeValue(forKey:token)
    cancelFlights(for:token)
    if refreshOwner==token { refreshTask?.cancel(); refreshTask=nil; refreshing=false; refreshed=false; refreshOwner=nil }
    condition.broadcast(); condition.unlock()
  }
  private func cancelFlights(for token:Int32) {
    for (id,f) in flights {
      f.readers.remove(token)
      if f.readers.isEmpty {
        if f.recovery.hadFailure && f.recovery.outcome=="recovering" { publishRecovery(f.recovery,outcome:"cancelled") }
        f.task?.cancel(); flights.removeValue(forKey:id); stats.cancelled+=1
      }
    }
  }
  func changeGeneration(_ value:Int32) {
    condition.lock()
    let previous=generation; generation=value; readerErrors.removeValue(forKey:previous)
    cancelFlights(for:previous)
    if value<0 {
      closed=true; previewTokens.removeAll()
      for f in flights.values { f.task?.cancel() }
      flights.removeAll()
    }
    if stats.terminalFailure==nil { stats.lastIssue=nil; stats.lastError=nil; issueOwner=nil }
    refreshTask?.cancel(); refreshTask=nil
    if refreshing { refreshing=false; refreshed=false }
    if stats.terminalFailure != nil, stats.clues.count<4 { stats.clues.append("subsequent cancellation generation=\(value)") }
    condition.broadcast(); condition.unlock()
    if value<0 { session.invalidateAndCancel() }
  }
  func close() { changeGeneration(-1) }
  private func issue(_ kind:RangeFailureKind, flight f:Flight, code:Int32, native:NSError? = nil) {
    f.error=code
    let domain=native.map { [NSURLErrorDomain,NSPOSIXErrorDomain,"kCFErrorDomainCFNetwork"].contains($0.domain) ? $0.domain : "other" } ?? "none"
    let evidence=RangeFailureEvidence(kind:kind,generation:f.generation,status:f.status,
      requestedStart:f.start,requestedEnd:f.end,contentRange:f.contentRange,
      declaredBytes:f.declaredBytes,receivedBytes:f.receivedBytes,hintedLength:identity.size,
      verifiedLength:length,observedLength:f.observedLength,redirects:f.redirects,
      applicationUAPreserved:f.uaPreserved,networkDomain:domain,networkCode:native?.code ?? 0)
    if stats.terminalFailure != nil, stats.clues.count<4 { stats.clues.append("subsequent transport=\(kind.rawValue)") }
    f.issue=evidence
    if f.readers.contains(generation) { stats.lastIssue=evidence; stats.lastError=kind.rawValue; issueOwner=f.recovery.id }
    if [.malformedResponse,.metadataConflict,.resourceChanged,.unsupportedBackend,.redirectPolicy].contains(kind) {
      for token in f.readers { readerErrors[token]=code }
      if f.readers.contains(generation) || [.resourceChanged,.metadataConflict].contains(kind) {
        if stats.terminalFailure==nil { stats.terminalFailure=evidence }
        if fatalError==nil { fatalError=code }
      }
      f.recovery.reason=kind.rawValue; publishRecovery(f.recovery,outcome:"rejected")
    }
  }
  private func publishRecovery(_ recovery:Recovery,outcome:String? = nil) {
    guard recovery.hadFailure else { return }
    if let outcome, recovery.outcome=="recovering" {
      recovery.outcome=outcome
      if outcome=="recovered" { stats.recovered+=1 }
      if outcome=="exhausted" { stats.exhausted+=1 }
      if outcome=="cancelled" { stats.recoveryCancelled+=1 }
    }
    stats.recovery=RangeRecoveryReport(generation:recovery.generation,outcome:recovery.outcome,
      elapsed:ProcessInfo.processInfo.systemUptime-recovery.started,reason:recovery.reason,attempts:recovery.attempts)
  }
  private func recovered(_ f:Flight) {
    guard f.recovery.hadFailure, f.recovery.outcome=="recovering" else { return }
    publishRecovery(f.recovery,outcome:"recovered")
    if stats.terminalFailure==nil, issueOwner==f.recovery.id { stats.lastIssue=nil; stats.lastError=nil; issueOwner=nil }
  }
  private func terminate(_ f:Flight, reader:Int32) -> Int32 {
    publishRecovery(f.recovery,outcome:"exhausted")
    f.finished=true; f.task?.cancel()
    let error:Int32=f.error == 0 ? -1 : f.error
    readerErrors[reader]=error
    if reader==generation {
      if stats.terminalFailure==nil { stats.terminalFailure=f.issue }
      if fatalError==nil { fatalError=error }
    }
    return error
  }
  private func flight(at offset:Int64,reader:Int32) -> Flight? {
    flights.values.first {
      $0.start<=offset && offset<=$0.end && ($0.error==0 || $0.readers.contains(reader) ||
        ([-1,-2,-10,-11].contains($0.error) && $0.recovery.outcome=="recovering"))
    }
  }
  /// Returns 0 only after HTTP confirms EOF. Negative outcomes retain typed evidence.
  func read(offset:Int64, buffer:UnsafeMutablePointer<UInt8>, count:Int, generation wanted:Int32) -> Int32 {
    condition.lock()
    let primary=wanted==generation
    if primary { primaryReaders+=1 }
    var result:Int32 = -1
    stats.lastReadOffset=offset; stats.lastReadCount=count
    defer {
      if primary { primaryReaders-=1; stats.lastReadResult=result }
      condition.broadcast(); condition.unlock()
    }
    guard offset>=0, count>0 else { return result }
    let base=offset/page*page, deadline=ProcessInfo.processInfo.systemUptime+9
    var observed=Set<Int>(), checkedDisk=false
    var continuation:Recovery?
    while true {
      if !valid(wanted) {
        if let continuation { publishRecovery(continuation,outcome:"cancelled") }
        result = -3; return result
      }
      if let fatalError=readerErrors[wanted] ?? fatalError {
        if let continuation { publishRecovery(continuation,outcome:"exhausted") }
        result=fatalError; return result
      }
      if length>=0, offset>=length { result=0; return result }
      if cacheEnabled, let cached=memory[base], cached.available(at:Int(offset-base))>0 {
        let start=Int(offset-base), n=min(count,cached.available(at:start))
        cached.data.copyBytes(to:buffer,from:start..<(start+n)); stats.memoryHitBytes+=Int64(n)
        order.removeAll { $0==base }; order.append(base); result=Int32(n); return result
      }
      // Authenticate this representation via HTTP before consulting old disk pages.
      if !checkedDisk, let key=diskKey, length>base {
        checkedDisk=true; let expected=Int(min(page,length-base))
        condition.unlock(); let bytes=disk.read(key:key,offset:base,length:expected); condition.lock()
        if !valid(wanted) { result = -3; return result }
        if let fatalError=readerErrors[wanted] ?? fatalError { result=fatalError; return result }
        if let bytes {
          storeVerified(bytes,at:base)
          let start=Int(offset-base), n=min(count,bytes.count-start)
          bytes.copyBytes(to:buffer,from:start..<(start+n)); stats.diskHitBytes+=Int64(n)
          result=Int32(n); return result
        }
      }
      let active=flight(at:offset,reader:wanted)
      let budget=active.map { $0.recovery.hadFailure && $0.recovery.outcome=="recovering" ? min(deadline,$0.recovery.started+9) : deadline } ?? continuation.map { min(deadline,$0.started+9) } ?? deadline
      if ProcessInfo.processInfo.systemUptime>=budget {
        let f=active ?? Flight(start:offset,end:offset,generation:wanted)
        f.recovery.reason="total-budget"
        issue(.timeout,flight:f,code:-2); result=terminate(f,reader:wanted); return result
      }
      if let f=flight(at:offset,reader:wanted) {
        f.readers.insert(wanted)
        if !cacheEnabled, offset<f.consumedThrough {
          f.task?.cancel(); if let id=f.task?.taskIdentifier { flights.removeValue(forKey:id) }; continue
        }
        if let id=f.task?.taskIdentifier, observed.insert(id).inserted { stats.coalesced+=1 }
        // Errors win over buffered prefixes after a failed response has completed.
        if f.finished, f.error != 0, !f.retryPending {
          if f.error == -5, !refreshed, let refresh {
            f.recovery.hadFailure=true
            if f.recovery.attempts.count>=3 { f.recovery.reason="attempt-limit"; result=terminate(f,reader:wanted); return result }
            continuation=f.recovery; publishRecovery(f.recovery)
            if let id=f.task?.taskIdentifier { flights.removeValue(forKey:id) }
            refreshed=true; refreshing=true; refreshOwner=wanted; stats.refreshes+=1
            refreshTask=Task.detached { [weak self] in
              do { self?.didRefresh(try await refresh(),generation:wanted) }
              catch { self?.didRefresh(nil,generation:wanted) }
            }
          } else if [-1,-2,-10,-11].contains(f.error) {
            let cycle=f.recovery
            cycle.hadFailure=true; publishRecovery(cycle)
            let budget=min(deadline,cycle.started+9)
            let backoff=f.error == -11 ? Double(cycle.attempts.count) : 0.25*pow(2,Double(cycle.attempts.count-1))
            let waited=cycle.attempts[f.attemptIndex].actualWait
            let delay=max(0,max(backoff,f.retryAfter ?? 0)-waited)
            if cycle.attempts.count>=3 || ProcessInfo.processInfo.systemUptime+delay>=budget {
              cycle.reason=cycle.attempts.count>=3 ? "attempt-limit" : "retry-after-exceeds-budget"
              result=terminate(f,reader:wanted); return result
            }
            f.retryPending=true // One waiter owns the retry; other readers coalesce.
            cycle.attempts[f.attemptIndex].plannedWait=waited+delay
            let waitStart=ProcessInfo.processInfo.systemUptime, until=waitStart+delay
            publishRecovery(cycle)
            while valid(wanted) && fatalError==nil && ProcessInfo.processInfo.systemUptime<until {
              _=condition.wait(until:Date(timeIntervalSinceNow:min(0.1,until-ProcessInfo.processInfo.systemUptime)))
              cycle.attempts[f.attemptIndex].actualWait=waited+ProcessInfo.processInfo.systemUptime-waitStart
            }
            cycle.attempts[f.attemptIndex].actualWait=waited+ProcessInfo.processInfo.systemUptime-waitStart
            publishRecovery(cycle)
            if !valid(wanted) {
              f.retryPending=false
              if f.readers.isEmpty { publishRecovery(cycle,outcome:"cancelled") }
              condition.broadcast(); result = -3; return result
            }
            if let fatalError=readerErrors[wanted] ?? fatalError { result=fatalError; return result }
            if ProcessInfo.processInfo.systemUptime>=budget { cycle.reason="total-budget"; result=terminate(f,reader:wanted); return result }
            guard let id=f.task?.taskIdentifier, flights[id] === f else { continue }
            flights.removeValue(forKey:id)
            let retryID=startFlight(at:offset,generation:wanted,recovery:cycle)
            flights[retryID]?.readers=f.readers
            observed.insert(retryID)
          } else { result=terminate(f,reader:wanted); return result }
          continue
        }
        let start=Int(offset-f.start)
        if f.accepted, start<f.data.count {
          let n=min(count,f.data.count-start)
          f.data.copyBytes(to:buffer,from:start..<(start+n)); f.consumedThrough=offset+Int64(n)
          recovered(f); result=Int32(n); return result
        }
        if f.finished && !f.retryPending {
          // A valid short prefix is complete, not a failed whole-window transfer.
          // The next request starts at the exact uncovered byte, never at page zero.
          if let id=f.task?.taskIdentifier { flights.removeValue(forKey:id) }; continue
        }
      } else if !refreshing {
        if flights.count>=2, let old=flights.values.first(where:{ $0.finished && !$0.retryPending }), let id=old.task?.taskIdentifier { flights.removeValue(forKey:id) }
        if flights.count<2, wanted==generation || (primaryReaders==0 && !flights.values.contains(where: { !$0.readers.contains(generation) && !$0.finished })) {
          observed.insert(startFlight(at:offset,generation:wanted,recovery:continuation)); continuation=nil
        }
      }
      _=condition.wait(until:Date(timeIntervalSinceNow:max(0,min(0.1,budget-ProcessInfo.processInfo.systemUptime))))
    }
  }
  @discardableResult private func storeVerified(_ data:Data,at start:Int64) -> [(Int64,Data)] {
    // Without an observed strong validator, do not combine fragments or reuse
    // pages across HTTP responses. Active response bytes can still stream.
    guard cacheEnabled, responseValidator != nil else { return [] }
    var cursor=0, complete:[(Int64,Data)]=[]
    while cursor<data.count {
      let absolute=start+Int64(cursor), base=absolute/page*page, inside=Int(absolute-base)
      let n=min(Int(page)-inside,data.count-cursor)
      var block=memory[base] ?? Page()
      if memory[base]==nil { stats.memoryBytes+=Int(page) }
      block.append(data.subdata(in:cursor..<(cursor+n)),at:inside); memory[base]=block
      order.removeAll { $0==base }; order.append(base)
      let required=Int(min(page,length-base))
      if required>0, block.available(at:0)>=required { complete.append((base,Data(block.data.prefix(required)))) }
      cursor+=n
    }
    while stats.memoryBytes>memoryLimit, let oldest=order.first {
      memory.removeValue(forKey:oldest); stats.memoryBytes-=Int(page); order.removeFirst()
    }
    return complete
  }
  private func startFlight(at start:Int64,generation:Int32,recovery:Recovery? = nil) -> Int {
    let span=cacheEnabled ? window : page
    let end=min(start+min(span-1,Int64.max-start),length>0 ? length-1 : Int64.max)
    let f=Flight(start:start,end:end,generation:generation,recovery:recovery)
    var request=URLRequest(url:source.url)
    if let recovery { request.timeoutInterval=max(0.01,min(5,recovery.started+9-ProcessInfo.processInfo.systemUptime)) }
    for (key,value) in source.headers { request.setValue(value,forHTTPHeaderField:key) }
    request.setValue("bytes=\(start)-\(end)",forHTTPHeaderField:"Range")
    request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
    if let responseValidator { request.setValue(responseValidator,forHTTPHeaderField:"If-Range") }
    let task=session.dataTask(with:request); f.task=task; flights[task.taskIdentifier]=f
    stats.requests+=1; stats.misses+=1; task.resume(); return task.taskIdentifier
  }
  private func didRefresh(_ value:VideoSource?,generation wanted:Int32) {
    condition.lock(); defer { condition.broadcast(); condition.unlock() }
    guard valid(wanted), refreshing else { return }
    refreshing=false; refreshTask=nil
    if let value, value.isOriginal==source.isOriginal { source=value }
    else {
      // Preserve the original 401/403 facts if refreshing the signed URL fails.
      readerErrors[wanted] = -5
      if wanted==generation {
        if stats.terminalFailure==nil { stats.terminalFailure=stats.lastIssue }
        if stats.clues.count<4 { stats.clues.append("URL refresh failed") }; fatalError = -5
      }
    }
  }
  private func verifyIdentity(total:Int64,validator:String?,flight f:Flight) -> Bool {
    f.observedLength=total
    if length>=0, length != total { issue(.resourceChanged,flight:f,code:-4); return false }
    if let prior=responseValidator, validator != prior { issue(.resourceChanged,flight:f,code:-4); return false }
    // A hint conflict cannot be authenticated by matching only a filename/URL.
    // No independent provider identity revalidation exists here: fail explicitly.
    if identity.size>0, identity.size != total { issue(.metadataConflict,flight:f,code:-7); return false }
    length=total; stats.verifiedLength=total
    if responseValidator==nil { responseValidator=validator }
    return true
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,
                  completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
    condition.lock()
    guard let f=flights[dataTask.taskIdentifier],let http=response as? HTTPURLResponse else { condition.unlock(); completionHandler(.cancel); return }
    f.status=http.statusCode; f.declaredBytes=http.expectedContentLength
    f.recovery.attempts[f.attemptIndex].status=http.statusCode
    f.retryAfter=Self.retryAfter(http.value(forHTTPHeaderField:"Retry-After"))
    f.recovery.attempts[f.attemptIndex].retryAfter=f.retryAfter
    switch http.statusCode { case 200:stats.responses200+=1; case 206:stats.responses206+=1; case 416:stats.responses416+=1; default:break }
    let validator=http.value(forHTTPHeaderField:"ETag").flatMap { $0.hasPrefix("\"") && $0.hasSuffix("\"") ? $0 : nil }
    let identityEncoding=http.value(forHTTPHeaderField:"Content-Encoding").map { $0.lowercased()=="identity" } ?? true
    var valid=false
    if http.statusCode==206,let raw=http.value(forHTTPHeaderField:"Content-Range"),let parsed=Self.contentRange(raw) {
      f.contentRange="bytes \(parsed.start)-\(parsed.end)/\(parsed.total)"; f.observedLength=parsed.total
      if parsed.start==f.start,parsed.end<=f.end,identityEncoding {
        let expected=parsed.end-parsed.start+1
        if http.expectedContentLength<0 || http.expectedContentLength==expected {
          f.expected=Int(expected); f.receivedEnd=parsed.end
          valid=verifyIdentity(total:parsed.total,validator:validator,flight:f)
        }
      }
    }
    if http.statusCode==200 {
      if f.start==0,http.expectedContentLength>0,http.expectedContentLength<=window,identityEncoding {
        f.expected=Int(http.expectedContentLength); f.receivedEnd=http.expectedContentLength-1
        valid=verifyIdentity(total:http.expectedContentLength,validator:validator,flight:f)
      } else { issue(.unsupportedBackend,flight:f,code:-8) }
    }
    if http.statusCode==416,let raw=http.value(forHTTPHeaderField:"Content-Range"),raw.hasPrefix("bytes */"),
       let total=Int64(raw.dropFirst(8)),total>=0 {
      f.contentRange="bytes */\(total)"; f.observedLength=total
      if f.start>=total {
        valid=verifyIdentity(total:total,validator:validator,flight:f)
        if valid { f.expected=0; f.finished=true }
      }
    }
    if !valid {
      if f.issue==nil {
        if [500,502,503,504].contains(http.statusCode) {
          issue(.serverError,flight:f,code:-10); f.recovery.hadFailure=true; publishRecovery(f.recovery)
        } else if http.statusCode==429 {
          issue(.rateLimited,flight:f,code:-11); f.recovery.hadFailure=true; publishRecovery(f.recovery)
        } else if [401,403].contains(http.statusCode) { issue(.authentication,flight:f,code:-5) }
        else if [200,206,416].contains(http.statusCode) { issue(.malformedResponse,flight:f,code:-6) }
        else { issue(.httpStatus,flight:f,code:-12) }
      }
      f.finished=true
    }
    f.accepted=valid; condition.broadcast(); condition.unlock(); completionHandler(valid ? .allow : .cancel)
  }
  /// RFC 9110 delay-seconds or HTTP-date. Never shorten a valid server delay;
  /// if it cannot fit the unchanged budget, the caller exhausts without retrying.
  static func retryAfter(_ value:String?, now:Date = Date()) -> Double? {
    guard let value=value?.trimmingCharacters(in:.whitespacesAndNewlines), !value.isEmpty else { return nil }
    if value.utf8.allSatisfy({ $0>=48 && $0<=57 }) { return min(Double(value) ?? .greatestFiniteMagnitude,Double.greatestFiniteMagnitude) }
    let formatter=DateFormatter(); formatter.locale=Locale(identifier:"en_US_POSIX")
    formatter.timeZone=TimeZone(secondsFromGMT:0); formatter.isLenient=false
    for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'","EEEE, dd-MMM-yy HH:mm:ss 'GMT'","EEE MMM d HH:mm:ss yyyy"] {
      formatter.dateFormat=format
      if let date=formatter.date(from:value) { return max(0,date.timeIntervalSince(now)) }
    }
    return nil
  }
  static func contentRange(_ text:String)->(start:Int64,end:Int64,total:Int64)? {
    guard text.hasPrefix("bytes ") else { return nil }
    let parts=text.dropFirst(6).split(separator:"/",omittingEmptySubsequences:false)
    guard parts.count==2,let total=Int64(parts[1]),total>0 else { return nil }
    let span=parts[0].split(separator:"-",omittingEmptySubsequences:false)
    guard span.count==2, (span+[parts[1]]).allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0>=48 && $0<=57 } }),let start=Int64(span[0]),let end=Int64(span[1]),start>=0,end>=start,end<total else { return nil }
    return(start,end,total)
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
    condition.lock(); stats.networkBytes+=Int64(data.count)
    guard let f=flights[dataTask.taskIdentifier],f.accepted,!f.finished else { condition.unlock(); return }
    f.receivedBytes+=data.count
    guard data.count<=f.expected-f.data.count else {
      issue(.malformedResponse,flight:f,code:-6); f.finished=true
      condition.broadcast(); condition.unlock(); dataTask.cancel(); return
    }
    f.data.append(data); condition.broadcast(); condition.unlock()
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    condition.lock()
    guard let f=flights[task.taskIdentifier] else { condition.unlock(); return }
    if !f.finished {
      f.finished=true
      if error != nil || !f.accepted || f.data.count != f.expected {
        let native=error as NSError?
        issue(native?.code==NSURLErrorTimedOut ? .timeout : error == nil ? .malformedResponse : .network,
          flight:f,code:native?.code==NSURLErrorTimedOut ? -2 : -1,native:native)
        // A partially delivered response that later breaks is not a legal short
        // prefix. Do not turn repeated disconnects into unbounded prefix retries.
        if f.receivedBytes>0 { for token in f.readers { _=terminate(f,reader:token) } }
      }
    }
    if f.error==0, f.accepted { recovered(f) }
    let pages=f.error==0 && f.accepted ? storeVerified(f.data,at:f.start) : []
    let key=diskKey
    condition.broadcast(); condition.unlock()
    if let key { for (offset,data) in pages { disk.write(data,key:key,offset:offset,epoch:diskEpoch) } }
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                  newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
    condition.lock()
    guard let f=flights[task.taskIdentifier] else { condition.unlock(); completionHandler(nil); return }
    f.redirects+=1
    let previous=response.url,next=request.url
    guard f.redirects<=5, let next, next.user==nil,next.password==nil,
      next.scheme=="https" || (previous?.scheme=="http" && next.scheme=="http") else {
      issue(.redirectPolicy,flight:f,code:-9); f.finished=true; condition.broadcast()
      condition.unlock(); completionHandler(nil); return
    }
    var redirected=request
    if previous?.host != next.host || previous?.port != next.port || previous?.scheme != next.scheme {
      redirected=URLRequest(url:next,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:5)
      // Only this explicitly public provider header survives. Never Referer,
      // Origin, cookies, bearer tokens or unknown/custom authorization headers.
      if let ua=source.headers.first(where:{ $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
        redirected.setValue(ua,forHTTPHeaderField:"User-Agent")
        f.uaPreserved=redirected.value(forHTTPHeaderField:"User-Agent")==ua
      }
    }
    redirected.setValue("bytes=\(f.start)-\(f.end)",forHTTPHeaderField:"Range")
    redirected.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
    // Do not forward a potentially identifying validator cross-origin. Every
    // response still must match the in-memory validator before bytes are used.
    if previous?.host != next.host || previous?.port != next.port || previous?.scheme != next.scheme {
      redirected.setValue(nil,forHTTPHeaderField:"If-Range")
    }
    stats.requests+=1; condition.unlock(); completionHandler(redirected)
  }
}
