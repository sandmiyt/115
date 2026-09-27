import Foundation
import CryptoKit

struct RangeCacheIdentity: Sendable {
  let account: String
  let fileID: String
  let size: Int64
  let validator: String
  var isPersistent: Bool {
    let hash=validator.lowercased()
    return size>0 && hash.hasPrefix("sha1:") && hash.count==45 && hash.dropFirst(5).allSatisfy { $0.isHexDigit }
  }
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

/// Durable byte coverage, never inferred media-time coverage. All mutation is on
/// the utility queue; admission is bounded before any Data is retained by it.
struct MediaCacheProgress: Sendable, Equatable {
  var bytes: Int64 = 0
  var total: Int64 = 0
  var complete = false
  var persistent = false
  var limitation: String?
}
final class SegmentDiskCache: @unchecked Sendable {
  static let shared = SegmentDiskCache()
  static let capacityPreference = "cineva.videoCache.capacityGiB"
  private let queue = DispatchQueue(label:"cineva.segment.disk",qos:.utility)
  private let admission = NSLock()
  private var pendingBytes = 0
  private var pendingFaults:Set<URL>=[]
  private let pendingLimit = 4*1048576
  private let root: URL
  private let capacity: @Sendable () -> Int64
  private let freeSpace: (@Sendable () -> Int64)?
  private var revision: UInt64 = 0
  private var leases: [String:Int] = [:]
  private var records: [String:Record] = [:]
  private var entries: [URL:(Int64,Date)] = [:]
  private var indexed = false
  private var invalidKeys:Set<String>=[]
  private var writeFailures:[String:String]=[:]
  private struct Record: Codable {
    var identity: String
    var total: Int64
    var validator: String
    var pages: Set<Int64> = []
    var stamps:[Int64:TimeInterval] = [:]
  }
  var epoch: UInt64 { queue.sync { revision } }
  var queuedWriteBytes:Int { admission.lock(); defer { admission.unlock() }; return pendingBytes }
  init(root:URL? = nil, capacity:@escaping @Sendable () -> Int64 = {
    Int64(UserDefaults.standard.integer(forKey:SegmentDiskCache.capacityPreference))*1073741824
  }, freeSpace:(@Sendable () -> Int64)? = nil) {
    self.root=root ?? FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
      .appendingPathComponent("CinevaSegments-v2",isDirectory:true)
    self.capacity=capacity; self.freeSpace=freeSpace
  }
  private func path(_ key:String,_ offset:Int64)->URL { root.appendingPathComponent("\(key)-\(offset).block") }
  private func manifest(_ key:String)->URL { root.appendingPathComponent(key+".index") }
  private func index() {
    guard !indexed else { return }; indexed=true
    for url in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? [] {
      if let v=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) {
        entries[url]=(Int64(v.fileSize ?? 0),v.contentModificationDate ?? .distantPast)
      }
    }
  }
  private func available() -> Int64 {
    if let freeSpace { return freeSpace() }
    let volume=(try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    return volume ?? ((try? FileManager.default.attributesOfFileSystem(forPath:root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
  }
  private func load(_ key:String)->Record? {
    guard !invalidKeys.contains(key) else { return nil }
    if let record=records[key] { return record }
    guard let data=try? Data(contentsOf:manifest(key)), data.count>32,
      Data(SHA256.hash(data:data.dropFirst(32)))==data.prefix(32),
      var record=try? JSONDecoder().decode(Record.self,from:data.dropFirst(32)), record.total>0 else { return nil }
    // Atomic manifests may survive system cache purging; missing/short blocks
    // are holes, never a complete file. Each read additionally checks its hash.
    let oldPages=record.pages
    record.pages=[]
    for offset in oldPages {
      guard offset>=0,offset%65536==0,offset<record.total else { continue }
      let url=path(key,offset)
      guard let info=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]),
        info.fileSize==Int(min(65536,record.total-offset))+32 else { continue }
      let stamp=info.contentModificationDate?.timeIntervalSince1970
      if stamp != record.stamps[offset] {
        guard let stored=try? Data(contentsOf:url),
          Data(SHA256.hash(data:stored.dropFirst(32)))==stored.prefix(32) else { continue }
      }
      record.pages.insert(offset); record.stamps[offset]=stamp
    }
    records[key]=record; return record
  }
  private func save(_ record:Record,key:String) throws {
    let data=try JSONEncoder().encode(record), stored=Data(SHA256.hash(data:data))+data
    try stored.write(to:manifest(key),options:.atomic)
    entries[manifest(key)]=(Int64(stored.count),Date()); records[key]=record
  }
  func invalidate(_ key:String) {
    queue.async {
      self.invalidKeys.insert(key); self.records.removeValue(forKey:key)
      self.index()
      for file in self.entries.keys where file.lastPathComponent.hasPrefix(key) {
        try? FileManager.default.removeItem(at:file); self.entries.removeValue(forKey:file)
      }
    }
  }
  func acquire(_ key:String) { queue.async { self.leases[key,default:0]+=1 } }
  func release(_ key:String) { queue.async { self.leases[key]=max(0,(self.leases[key] ?? 1)-1) } }
  private func progress(_ record:Record?, persistent:Bool, limitation:String? = nil)->MediaCacheProgress {
    guard let record else { return MediaCacheProgress(persistent:persistent,limitation:limitation) }
    let bytes=record.pages.reduce(Int64(0)) { $0+min(65536,record.total-$1) }
    return MediaCacheProgress(bytes:bytes,total:record.total,complete:bytes==record.total,
      persistent:persistent,limitation:limitation)
  }
  // Evict other, inactive media only. The active file never evicts its own head.
  private func room(for bytes:Int64, key:String)->Bool {
    index()
    let limit=capacity(), reserve:Int64=1073741824
    guard bytes>=0,bytes<=Int64.max-reserve else { return false }
    let protected=entries.filter { entry in
      let owner=String(entry.key.lastPathComponent.prefix(64))
      return owner==key || (leases[owner] ?? 0)>0
    }.values.reduce(Int64(0)) { $0+$1.0 }
    if limit>0,protected+bytes>limit { return false }
    func enough()->Bool {
      let used=entries.values.reduce(Int64(0)) { $0+$1.0 }
      return available()>=bytes+reserve && (limit<=0 || used+bytes<=limit)
    }
    if enough() { return true }
    for entry in entries.filter({ entry in
      let owner=String(entry.key.lastPathComponent.prefix(64))
      return owner != key && (leases[owner] ?? 0)==0
    }).sorted(by: { $0.value.1<$1.value.1 }).prefix(64) {
      let owner=String(entry.key.lastPathComponent.prefix(64))
      guard owner != key, (leases[owner] ?? 0)==0 else { continue }
      if (try? FileManager.default.removeItem(at:entry.key)) != nil {
        entries.removeValue(forKey:entry.key); records.removeValue(forKey:owner)
      }
      if enough() { return true }
    }
    return enough()
  }
  func inspect(key:String,identity:String,total:Int64,validator:String,persistent:Bool,
               reserveWhole:Bool = false)->(MediaCacheProgress,Set<Int64>) {
    queue.sync {
      try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      let record=load(key) ?? Record(identity:identity,total:total,validator:validator)
      guard record.identity==identity,record.total==total,record.validator==validator else {
        return (MediaCacheProgress(limitation:"媒体身份不匹配，停止额外下载"),[])
      }
      records[key]=record
      let bytes=record.pages.reduce(Int64(0)) { $0+min(65536,total-$1) }
      let missing=max(0,total-bytes), overhead=(missing/65536+1)*8192+1048576
      let limited=reserveWhole && (missing>Int64.max-overhead || !room(for:missing+overhead,key:key))
      let message=limited ? "空间或视频缓存额度不足，已暂停整片下载；正常播放不受影响" : writeFailures[key]
      // Record is intentionally created before the first async page batch.
      if !FileManager.default.fileExists(atPath:manifest(key).path) { try? save(record,key:key) }
      return (progress(record,persistent:persistent,limitation:message),record.pages)
    }
  }
  func restored(identity:String,recheck:Bool = true)->(key:String,total:Int64,validator:String,complete:Bool)? {
    queue.sync {
      // A provider content hash + account/file/size identity is required by caller.
      let key=identity
      if recheck { records.removeValue(forKey:key) }
      guard let record=load(key),record.identity==identity else { return nil }
      return (key,record.total,record.validator,progress(record,persistent:true).complete)
    }
  }
  private func discardPage(key:String,offset:Int64,length:Int,file:URL) {
    admission.lock()
    guard pendingFaults.count<64,pendingFaults.insert(file).inserted else { admission.unlock(); return }
    admission.unlock()
    queue.async {
      defer { self.admission.lock(); self.pendingFaults.remove(file); self.admission.unlock() }
      // A queued atomic writer may already have repaired a miss/corrupt page.
      if let current=try? Data(contentsOf:file),current.count==length+32,
        Data(SHA256.hash(data:current.dropFirst(32)))==current.prefix(32) { return }
      if var record=self.records[key],record.pages.remove(offset) != nil {
        try? self.save(record,key:key)
      }
      try? FileManager.default.removeItem(at:file); self.entries.removeValue(forKey:file)
    }
  }
  func read(key:String,offset:Int64,length:Int)->Data? {
    // Atomic immutable blocks can be read without joining the writer/eviction
    // queue. A foreground seek must not wait behind speculative persistence.
    let file=path(key,offset)
    guard let stored=try? Data(contentsOf:file),stored.count==length+32,
      Data(SHA256.hash(data:stored.dropFirst(32)))==stored.prefix(32) else {
      discardPage(key:key,offset:offset,length:length,file:file); return nil
    }
    return Data(stored.dropFirst(32))
  }
  @discardableResult func enqueue(_ pages:[(Int64,Data)],key:String,epoch:UInt64,
                                  identity:String? = nil,total:Int64 = 0,validator:String = "",
                                  completion:@escaping @Sendable ()->Void)->Bool {
    let cost=pages.reduce(0) { $0+$1.1.count }
    guard cost>0,cost<=pendingLimit else { return false }
    admission.lock()
    guard pendingBytes+cost<=pendingLimit else { admission.unlock(); return false }
    pendingBytes+=cost; admission.unlock()
    queue.async {
      defer {
        self.admission.lock(); self.pendingBytes-=cost; self.admission.unlock(); completion()
      }
      guard epoch==self.revision,!self.invalidKeys.contains(key) else { return }
      try? FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true)
      var excluded=self.root, attributes=URLResourceValues(); attributes.isExcludedFromBackup=true
      try? excluded.setResourceValues(attributes)
      guard var record=self.load(key) ?? identity.map({ Record(identity:$0,total:total,validator:validator) }),record.total>0 else { return }
      let fresh=pages.filter { !record.pages.contains($0.0) }
      guard self.room(for:Int64(fresh.reduce(0) { $0+$1.1.count+32 })+1048576,key:key) else {
        self.writeFailures[key]="空间或视频缓存额度不足，已暂停写入；正常播放不受影响"; return
      }
      do {
        for (offset,data) in fresh {
          guard offset>=0,offset%65536==0,offset<record.total,
            data.count==Int(min(65536,record.total-offset)) else { continue }
          let stored=Data(SHA256.hash(data:data))+data, file=self.path(key,offset)
          try stored.write(to:file,options:.atomic)
          self.entries[file]=(Int64(stored.count),Date()); record.pages.insert(offset)
          record.stamps[offset]=(try? file.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
        }
        try self.save(record,key:key); self.writeFailures.removeValue(forKey:key)
      } catch {
        self.writeFailures[key]="无法完成磁盘写入，已暂停整片下载；正常播放不受影响"
      }
    }
    return true
  }
  // Test/maintenance compatibility. Production callbacks only use bounded enqueue.
  func write(_ data:Data,key:String,offset:Int64,epoch:UInt64) {
    queue.sync {
      guard epoch==revision else { return }
      try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
      try? (Data(SHA256.hash(data:data))+data).write(to:path(key,offset),options:.atomic)
    }
  }
  func flush() { queue.sync {} }
  func clear() { queue.sync {
    revision &+= 1; try? FileManager.default.removeItem(at:root)
    entries.removeAll(); records.removeAll(); invalidKeys.removeAll(); writeFailures.removeAll(); indexed=false
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
  private let sessionKey=UUID().uuidString
  private let maintenance=DispatchQueue(label:"cineva.range.prefetch",qos:.utility)
  private var maintenanceTimer:DispatchSourceTimer?
  private var prefetchAllowed=false
  private var prefetchToken:Int32?
  private var prefetchRetryAt=0.0
  private var durablePages:Set<Int64>=[]
  private var diskProgress=MediaCacheProgress()
  private var acquiredKey:String?
  private var lastForegroundMiss=ProcessInfo.processInfo.systemUptime
  private var diskKey:String? {
    guard cacheEnabled,length>0,responseValidator != nil else { return nil }
    if identity.isPersistent { return identity.key }
    // A strong HTTP validator permits merging within this session, but without
    // provider content identity it must not silently promise reuse after reopen.
    return RangeCacheIdentity(account:identity.account,fileID:identity.fileID,size:length,
      validator:identity.validator.isEmpty ? "session:"+sessionKey : "http-v3:"+identity.validator+":"+(responseValidator ?? "")).key
  }
  var mediaCacheProgress:MediaCacheProgress {
    condition.lock(); defer { condition.unlock() }; return diskProgress
  }
  func allowPrefetch(_ allowed:Bool) {
    condition.lock(); defer { condition.broadcast(); condition.unlock() }
    prefetchAllowed=allowed
    if !allowed { yieldPrefetch() }
  }
  private func yieldPrefetch() {
    guard let token=prefetchToken else { return }
    previewTokens.remove(token); readerErrors.removeValue(forKey:token)
    cancelFlights(for:token); prefetchToken=nil
    if refreshOwner==token {
      refreshTask?.cancel(); refreshTask=nil; refreshing=false; refreshed=false; refreshOwner=nil
    }
  }
  private func maintain() {
    condition.lock()
    guard !closed, fatalError==nil else { condition.unlock(); return }
    guard let key=diskKey,let validator=responseValidator else {
      if length<0 { diskProgress=MediaCacheProgress(); condition.unlock(); return }
      diskProgress=MediaCacheProgress(total:max(0,length),limitation:cacheEnabled
        ? "尚无可靠的媒体响应标识，仅在线播放，未写入磁盘" : "此媒体使用在线播放")
      condition.unlock(); return
    }
    let total=length, enabled=prefetchAllowed && ProcessInfo.processInfo.systemUptime>=prefetchRetryAt
    if acquiredKey==nil { acquiredKey=key; disk.acquire(key) }
    condition.unlock()
    // All filesystem work runs here/on the disk utility queue, never on the
    // serial URLSession delegate or main actor. inspect also drains prior writes.
    let (progress,pages)=disk.inspect(key:key,identity:identity.isPersistent ? identity.key : key,
      total:total,validator:validator,persistent:identity.isPersistent,reserveWhole:enabled)
    condition.lock()
    guard !closed,fatalError==nil,diskKey==key else { condition.unlock(); return }
    diskProgress=progress; durablePages=pages
    if ProcessInfo.processInfo.systemUptime<prefetchRetryAt {
      diskProgress.limitation="整片下载暂时中断，稍后重试；正常播放仍可继续"
    }
    var batch:[(Int64,Data)]=[]
    for offset in order where !pages.contains(offset) {
      let count=Int(min(page,total-offset))
      if count>0,let block=memory[offset],block.available(at:0)>=count {
        batch.append((offset,Data(block.data.prefix(count))))
        if batch.count>=64 { break }
      }
    }
    let mayDownload=enabled && prefetchAllowed && progress.limitation==nil && !progress.complete
      && primaryReaders==0 && ProcessInfo.processInfo.systemUptime-lastForegroundMiss>=1
      && !flights.values.contains(where: { !$0.finished })
    condition.unlock()
    if !batch.isEmpty {
      _=disk.enqueue(batch,key:key,epoch:diskEpoch,completion:{})
      return // Drain persistence before requesting more bytes; bounded backpressure.
    }
    guard mayDownload else { return }
    condition.lock()
    guard !closed,prefetchAllowed,primaryReaders==0 else { condition.unlock(); return }
    // First exact uncovered byte. Complete disk pages and partial memory spans
    // both count, so a short 206 never causes a restart at page/file zero.
    var offset:Int64=0
    while offset<total {
      let base=offset/page*page
      if durablePages.contains(base) { offset=min(total,base+page); continue }
      if let block=memory[base],block.available(at:Int(offset-base))>0 {
        offset+=Int64(block.available(at:Int(offset-base))); continue
      }
      break
    }
    guard offset<total else { condition.unlock(); return }
    nextPreviewToken+=1; let token=nextPreviewToken
    previewTokens.insert(token); prefetchToken=token
    condition.unlock()
    var bytes=[UInt8](repeating:0,count:65536)
    let end=offset+min(window,total-offset)
    while offset<end {
      let n=read(offset:offset,buffer:&bytes,count:Int(min(65536,end-offset)),generation:token)
      if n<=0 {
        condition.lock()
        if n != -3 { prefetchRetryAt=ProcessInfo.processInfo.systemUptime+30; diskProgress.limitation="整片下载暂时中断，正常播放仍可继续" }
        condition.unlock(); break
      }
      offset+=Int64(n)
    }
    // The accepted response can finish after its incremental read returned.
    condition.lock()
    while valid(token),flights.values.contains(where: { $0.readers.contains(token) && !$0.finished }) {
      _=condition.wait(until:Date(timeIntervalSinceNow:0.05))
    }
    if prefetchToken==token { yieldPrefetch() }
    condition.broadcast(); condition.unlock()
  }
  init(source: VideoSource, identity: RangeCacheIdentity, disk: SegmentDiskCache = .shared,
       cacheEnabled: Bool = true, refresh: Refresh? = nil) {
    self.source=source; self.identity=identity; self.disk=disk; self.refresh=refresh
    self.cacheEnabled=cacheEnabled; diskEpoch=disk.epoch; stats.hintedLength=identity.size
    if cacheEnabled,identity.isPersistent,let restored=disk.restored(identity:identity.key,recheck:false) {
      length=restored.total; responseValidator=restored.validator; stats.verifiedLength=length
    }
    super.init()
    let config=URLSessionConfiguration.ephemeral
    config.urlCache=nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage=nil; config.httpShouldSetCookies=false
    config.timeoutIntervalForRequest=5; config.timeoutIntervalForResource=12
    config.httpMaximumConnectionsPerHost=2
    let queue=OperationQueue(); queue.maxConcurrentOperationCount=1; queue.qualityOfService = .userInitiated
    session=URLSession(configuration:config,delegate:self,delegateQueue:queue)
    let timer=DispatchSource.makeTimerSource(queue:maintenance)
    timer.schedule(deadline:.now(),repeating:.milliseconds(200))
    timer.setEventHandler { [weak self] in self?.maintain() }
    maintenanceTimer=timer; timer.resume()
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
    guard !closed else { condition.unlock(); return }
    yieldPrefetch(); prefetchAllowed=false
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
    if value<0 {
      maintenanceTimer?.cancel(); maintenanceTimer=nil; session.invalidateAndCancel()
      if let key=acquiredKey { disk.release(key) }
    }
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
    if [.resourceChanged,.metadataConflict].contains(kind) {
      if let key=diskKey { disk.invalidate(key) }
      diskProgress=MediaCacheProgress(limitation:"媒体内容已变化，旧缓存已失效")
      durablePages.removeAll(); memory.removeAll(); order.removeAll(); stats.memoryBytes=0
    }
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
      // The OS may purge a formerly complete cache. Resolve the real source
      // only after an actual local hole, never as a prerequisite for local open.
      if source.url.scheme=="cineva-cache",!refreshing {
        guard !refreshed,let refresh else { result = -1; return result }
        refreshed=true; refreshing=true; refreshOwner=wanted; stats.refreshes+=1
        refreshTask=Task.detached { [weak self] in
          do { self?.didRefresh(try await refresh(),generation:wanted) }
          catch { self?.didRefresh(nil,generation:wanted) }
        }
      }
      if primary {
        lastForegroundMiss=ProcessInfo.processInfo.systemUptime
        // Coalesce an exact active range; unrelated speculative work yields now.
        let shared=flight(at:offset,reader:wanted)
        if let shared { shared.readers.insert(wanted); shared.task?.priority=URLSessionTask.highPriority }
        if let token=prefetchToken,shared?.readers.contains(token) != true { yieldPrefetch() }
        for (id,f) in flights where !f.finished && !f.readers.contains(generation) {
          f.task?.cancel(); flights.removeValue(forKey:id)
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
    var end=min(start+min(span-1,Int64.max-start),length>0 ? length-1 : Int64.max)
    // Stop at the next actual cached span instead of re-downloading its bytes.
    if cacheEnabled {
      var base=start/page*page
      while base<=end {
        if durablePages.contains(base),base>start { end=min(end,base-1); break }
        if let block=memory[base],let next=block.coverage.first(where: { base+Int64($0.lowerBound)>start }) {
          end=min(end,base+Int64(next.lowerBound)-1); break
        }
        if base>Int64.max-page { break }
        base+=page
      }
    }
    let f=Flight(start:start,end:end,generation:generation,recovery:recovery)
    var request=URLRequest(url:source.url)
    if let recovery { request.timeoutInterval=max(0.01,min(5,recovery.started+9-ProcessInfo.processInfo.systemUptime)) }
    for (key,value) in source.headers { request.setValue(value,forHTTPHeaderField:key) }
    request.setValue("bytes=\(start)-\(end)",forHTTPHeaderField:"Range")
    request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
    if let responseValidator { request.setValue(responseValidator,forHTTPHeaderField:"If-Range") }
    let task=session.dataTask(with:request); f.task=task; flights[task.taskIdentifier]=f
    task.priority=generation==self.generation ? URLSessionTask.highPriority : URLSessionTask.lowPriority
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
    if valid { refreshed=false }
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
    let key=diskKey, total=length, validator=responseValidator ?? ""
    if let key, acquiredKey==nil { acquiredKey=key; disk.acquire(key) }
    condition.broadcast(); condition.unlock()
    if let key {
      // Admission only takes a small lock; hashing, filesystem I/O, manifests
      // and eviction happen after playback readers have been signalled.
      _=disk.enqueue(pages,key:key,epoch:diskEpoch,
        identity:identity.isPersistent ? identity.key : key,total:total,validator:validator,completion:{})
    }
    // Rejected batches stay in bounded memory and are retried by maintenance.

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
