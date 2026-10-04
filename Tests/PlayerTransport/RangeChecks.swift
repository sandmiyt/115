import Foundation

private final class PendingRangeRead: @unchecked Sendable {
  let started=DispatchSemaphore(value:0), done=DispatchSemaphore(value:0)
  private let lock=NSLock()
  private var value:Int32?
  private var integrity=true
  var result:Int32? { lock.lock(); defer { lock.unlock() }; return value }
  var validBytes:Bool { lock.lock(); defer { lock.unlock() }; return integrity }
  func start(_ client:RangeCoordinator,at offset:Int64,generation:Int32 = 1) {
    DispatchQueue.global().async {
      var bytes=[UInt8](repeating:0,count:4096)
      self.started.signal()
      let n=client.read(offset:offset,buffer:&bytes,count:4096,generation:generation)
      let valid=n<=0 || (0..<Int(n)).allSatisfy { bytes[$0]==UInt8((offset+Int64($0))%251) }
      self.lock.lock(); self.value=n; self.integrity=valid; self.lock.unlock(); self.done.signal()
    }
  }
}

private final class SlowDiskGate: @unchecked Sendable {
  let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
  private let lock=NSLock()
  private var first=true
  func available()->Int64 {
    lock.lock(); let block=first; first=false; lock.unlock()
    if block { entered.signal(); _=release.wait(timeout:.now()+15) }
    return 8*1073741824
  }
}

@main struct RangeChecks {
  static func main() throws {
    let base=CommandLine.arguments[1]
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let disk=SegmentDiskCache(root:root), size:Int64=3*1048576+97
    @Sendable func source(_ path: String, headers: [String:String] = [:]) -> VideoSource {
      VideoSource(id:"fixture",title:"fixture",definition:0,url:URL(string:base+path)!,kind:.original,headers:headers)
    }
    func client(_ path: String, size: Int64 = 3*1048576+97, id: String = UUID().uuidString,
                version: String = "fixture-v1", cacheEnabled: Bool = true, persistenceEnabled: Bool = false,
                headers: [String:String] = [:], refresh: RangeCoordinator.Refresh? = nil) -> RangeCoordinator {
      RangeCoordinator(source:source(path,headers:headers),identity:RangeCacheIdentity(account:"test-account",fileID:id,size:size,validator:version),disk:disk,cacheEnabled:cacheEnabled,persistenceEnabled:persistenceEnabled,refresh:refresh)
    }
    var checks=0
    func expect(_ ok: Bool,_ message: String) { precondition(ok,message); checks+=1 }
    func read(_ c: RangeCoordinator,_ offset: Int64,_ count: Int = 4096,_ generation: Int32 = 1) -> Int32 {
      var bytes=[UInt8](repeating:0,count:count)
      let n=c.read(offset:offset,buffer:&bytes,count:count,generation:generation)
      if n<0 { print("Range result \(n) at \(offset): \(c.statistics)"); fflush(stdout) }
      if n>0 { expect((0..<Int(n)).allSatisfy { bytes[$0]==UInt8((offset+Int64($0))%251) },"Byte integrity at \(offset)") }
      return n
    }
    let streamingRoot=root.appendingPathComponent("streaming-only")
    try FileManager.default.createDirectory(at:streamingRoot,withIntermediateDirectories:true)
    let streamingDisk=SegmentDiskCache(root:streamingRoot)
    let streamingSize:Int64=40*1048576+97
    let streamingIdentity=RangeCacheIdentity(account:"streaming",fileID:"movie",size:streamingSize,
      validator:"sha1:"+String(repeating:"c",count:40))
    let streaming=RangeCoordinator(source:source("/fragment"),identity:streamingIdentity,disk:streamingDisk)
    expect(read(streaming,0)>0,"Default streaming delivers validated bytes without durable caching")
    for _ in 0..<200 where streaming.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.005) }
    expect(streaming.statistics.networkBytes==1048576 && streaming.statistics.memoryBytes==1048576,
      "Only the requested startup window is transferred and committed to valid memory")
    let startupRequests=streaming.statistics.requests
    streaming.allowPrefetch(true)
    Thread.sleep(forTimeInterval:1.4)
    expect(streaming.statistics.requests==startupRequests && streaming.statistics.networkBytes==1048576,
      "Default streaming never starts whole-file prefetch, even if a caller enables it")
    streaming.changeGeneration(2)
    let hitRequests=streaming.statistics.requests
    expect(read(streaming,32768,4096,2)>0 && streaming.statistics.requests==hitRequests
      && streaming.statistics.memoryHitBytes>0,"Streaming seek reuses valid bounded memory without redownload")
    for window in 1..<40 {
      expect(read(streaming,Int64(window)*1048576,4096,2)>0,"Streaming rolling window \(window)")
      for _ in 0..<200 where streaming.statistics.networkBytes<Int64(window+1)*1048576 {
        Thread.sleep(forTimeInterval:0.005)
      }
      expect(streaming.statistics.networkBytes==Int64(window+1)*1048576,
        "Requested streaming window finishes before moving to the next one")
      expect(streaming.statistics.memoryBytes<=32*1048576,"Streaming retained media stays within 32 MiB")
      expect(streamingDisk.queuedWriteBytes==0,"Streaming has no pending disk writes")
    }
    expect(streaming.statistics.diskHitBytes==0 && streaming.mediaCacheProgress.bytes==0
      && !streaming.mediaCacheProgress.complete,"Rolling memory never masquerades as a complete durable file")
    let evictedRequests=streaming.statistics.requests
    expect(read(streaming,0,4096,2)>0 && streaming.statistics.requests>evictedRequests,
      "Evicted streaming bytes are fetched normally instead of reading stale memory")
    streaming.close(); streamingDisk.flush()
    expect((try FileManager.default.contentsOfDirectory(atPath:streamingRoot.path)).isEmpty,
      "Default streaming creates no segment or manifest files")
    let reopenedStream=RangeCoordinator(source:source("/expired"),identity:streamingIdentity,disk:streamingDisk)
    expect(reopenedStream.fileSize == -1 && read(reopenedStream,0)<0
      && reopenedStream.statistics.requests==1 && reopenedStream.statistics.diskHitBytes==0,
      "A reopened default stream cannot silently resurrect an old whole-file cache")
    reopenedStream.close()
    // A partially downloaded file must suppress buffering feedback when this
    // seek hits cached bytes, independently of preview/prefetch network work.
    let feedback=client("/retry-stop?seek-feedback")
    expect(read(feedback,0)>0,"Prime a partial cache for seek feedback")
    for _ in 0..<200 where feedback.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
    feedback.changeGeneration(2)
    var readiness=CachedSeekReadiness(); readiness.begin(generation:2)
    expect(read(feedback,4096,4096,2)>0,"Seek reads an already cached region")
    readiness.observe(feedback.playbackReadState,buffering:true)
    expect(!feedback.mediaCacheProgress.complete && !readiness.needsNetwork,
      "Partial memory cache hit does not show a buffering prompt")
    let previewReader=feedback.makePreviewToken(), previewBlocked=PendingRangeRead()
    previewBlocked.start(feedback,at:1048576,generation:previewReader)
    for _ in 0..<200 where feedback.statistics.requests<2 { Thread.sleep(forTimeInterval:0.005) }
    readiness.observe(feedback.playbackReadState,buffering:true)
    expect(!readiness.needsNetwork && feedback.playbackReadState.networkWaits==0,
      "Preview network activity cannot enable primary seek feedback")
    feedback.cancelPreview(previewReader)
    expect(previewBlocked.done.wait(timeout:.now()+1) == .success,"Preview read cancels independently")
    let miss=PendingRangeRead(); miss.start(feedback,at:2097152,generation:2)
    for _ in 0..<200 where !feedback.playbackReadState.waitingForNetwork { Thread.sleep(forTimeInterval:0.005) }
    let staleRead=feedback.playbackReadState
    readiness.observe(staleRead,buffering:true)
    expect(readiness.needsNetwork,"Uncached target enables genuine network buffering feedback")
    feedback.changeGeneration(3); readiness.begin(generation:3)
    expect(miss.done.wait(timeout:.now()+1) == .success && miss.result == -3,"New seek cancels old waiting read")
    readiness.observe(staleRead,buffering:true)
    expect(read(feedback,0,4096,3)>0,"Cached target remains available after cancelling a miss")
    readiness.observe(feedback.playbackReadState,buffering:true)
    expect(!readiness.needsNetwork && !feedback.playbackReadState.waitingForNetwork,
      "Old seek cannot re-enable the spinner or leave a pending network reader")
    readiness.observe(feedback.playbackReadState,buffering:false)
    readiness.observe(feedback.playbackReadState,buffering:true)
    expect(!readiness.needsNetwork,"Local decode underrun stays on local recovery without network feedback")
    feedback.close()
    let gated=client("/ok?preview-pause-gate")
    expect(read(gated,0)>0,"Prime memory before pausing preview reads")
    for _ in 0..<200 where gated.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.005) }
    gated.setPreviewReadsAllowed(false)
    let gatedToken=gated.makePreviewToken(), gatedPreview=PendingRangeRead()
    let beforeGate=gated.statistics.requests
    gatedPreview.start(gated,at:1048576,generation:gatedToken)
    expect(gatedPreview.started.wait(timeout:.now()+1) == .success,"Preview read reaches paused gate")
    Thread.sleep(forTimeInterval:0.05)
    expect(gatedPreview.result==nil && gated.statistics.requests==beforeGate,
      "Paused preview does not start an HTTP request")
    expect(read(gated,32768)>0 && gated.statistics.requests==beforeGate,
      "Paused preview gate leaves primary memory hits available")
    expect(read(gated,2097152)>0 && gated.statistics.requests==beforeGate+1,
      "Paused preview gate leaves primary network misses available")
    gated.setPreviewReadsAllowed(true)
    expect(gatedPreview.done.wait(timeout:.now()+2) == .success
      && (gatedPreview.result ?? -1)>0 && gatedPreview.validBytes,
      "Resumed preview returns real validated bytes from its independent cursor")
    expect(gated.statistics.requests==beforeGate+2,"Resumed preview fetches only its missing window")
    gated.setPreviewReadsAllowed(false)
    let cancelledGate=gated.makePreviewToken(), cancelledGateRead=PendingRangeRead()
    cancelledGateRead.start(gated,at:0,generation:cancelledGate)
    expect(cancelledGateRead.started.wait(timeout:.now()+1) == .success,"Cancelled fixture enters paused preview gate")
    Thread.sleep(forTimeInterval:0.05)
    let beforeCancelledGate=gated.statistics.requests
    gated.cancelPreview(cancelledGate)
    expect(cancelledGateRead.done.wait(timeout:.now()+1) == .success && cancelledGateRead.result == -3,
      "Cancelling a paused preview wakes its read immediately")
    expect(read(gated,0)>0 && gated.statistics.requests==beforeCancelledGate
      && gated.statistics.terminalFailure==nil,"Paused preview cancellation preserves primary bytes and status")
    gated.cancelPreview(gatedToken); gated.close()
    let pausedShared=client("/slow?pause-shared-flight")
    let pausedSharedToken=pausedShared.makePreviewToken()
    expect(read(pausedShared,0,4096,pausedSharedToken)>0,"Preview starts a streaming shared flight")
    expect(read(pausedShared,0)>0,"Primary attaches to preview-owned flight")
    let sharedRequests=pausedShared.statistics.requests, sharedCancelled=pausedShared.statistics.cancelled
    pausedShared.setPreviewReadsAllowed(false)
    expect(read(pausedShared,65536)>0 && pausedShared.statistics.requests==sharedRequests
      && pausedShared.statistics.cancelled==sharedCancelled,
      "Pausing preview removes only its reader and preserves the primary shared transfer")
    let pausedSharedWait=PendingRangeRead()
    pausedSharedWait.start(pausedShared,at:131072,generation:pausedSharedToken)
    expect(pausedSharedWait.started.wait(timeout:.now()+1) == .success,"Shared preview waits behind paused gate")
    Thread.sleep(forTimeInterval:0.05)
    expect(pausedSharedWait.result==nil && pausedShared.statistics.requests==sharedRequests,
      "A paused shared preview cannot reopen or replace the primary flight")
    pausedShared.setPreviewReadsAllowed(true)
    expect(pausedSharedWait.done.wait(timeout:.now()+2) == .success
      && (pausedSharedWait.result ?? -1)>0 && pausedSharedWait.validBytes
      && pausedShared.statistics.requests==sharedRequests,
      "Resumed preview rejoins the existing shared transfer without another HTTP request")
    pausedShared.cancelPreview(pausedSharedToken); pausedShared.close()
    // Server retry state keys include the complete query and requested offset,
    // so these cases cannot inherit a successful attempt from another fixture.
    let pausedRetry=client("/retry-503?paused-owner="+UUID().uuidString)
    let pausedRetryToken=pausedRetry.makePreviewToken(), pausedRetryRead=PendingRangeRead()
    pausedRetryRead.start(pausedRetry,at:22345,generation:pausedRetryToken)
    for _ in 0..<100 where (pausedRetry.statistics.recovery?.attempts.first?.plannedWait ?? 0)<1 {
      Thread.sleep(forTimeInterval:0.005)
    }
    expect(pausedRetry.statistics.requests==1 && pausedRetry.statistics.recovery?.attempts.first?.status==503
      && (pausedRetry.statistics.recovery?.attempts.first?.plannedWait ?? 0)>=1,
      "Preview owns the initial one-second 503 backoff before being paused")
    pausedRetry.setPreviewReadsAllowed(false)
    Thread.sleep(forTimeInterval:1.25)
    expect(pausedRetry.statistics.requests==1 && pausedRetryRead.result==nil,
      "Paused preview cannot issue a retry after its original backoff expires")
    pausedRetry.setPreviewReadsAllowed(true)
    expect(pausedRetryRead.done.wait(timeout:.now()+2) == .success
      && (pausedRetryRead.result ?? -1)>0 && pausedRetryRead.validBytes
      && pausedRetry.statistics.requests==2,
      "Resumed independent preview recovers with one real successful retry")
    pausedRetry.cancelPreview(pausedRetryToken); pausedRetry.close()
    let handoffRetry=client("/retry-503?paused-owner-primary="+UUID().uuidString)
    let handoffToken=handoffRetry.makePreviewToken(), handoffOwner=PendingRangeRead(), handoffPrimary=PendingRangeRead()
    handoffOwner.start(handoffRetry,at:32768,generation:handoffToken)
    for _ in 0..<100 where (handoffRetry.statistics.recovery?.attempts.first?.plannedWait ?? 0)<1 {
      Thread.sleep(forTimeInterval:0.005)
    }
    expect(handoffRetry.statistics.requests==1 && handoffRetry.statistics.recovery?.attempts.first?.status==503,
      "Shared handoff begins with preview-owned failed request")
    handoffPrimary.start(handoffRetry,at:32768)
    for _ in 0..<100 where !handoffRetry.playbackReadState.waitingForNetwork {
      Thread.sleep(forTimeInterval:0.005)
    }
    expect(handoffRetry.playbackReadState.waitingForNetwork && handoffRetry.statistics.requests==1,
      "Primary has joined the existing preview retry rather than starting another request")
    handoffRetry.setPreviewReadsAllowed(false)
    expect(handoffPrimary.done.wait(timeout:.now()+3) == .success
      && (handoffPrimary.result ?? -1)>0 && handoffPrimary.validBytes
      && handoffRetry.statistics.requests==2 && handoffRetry.statistics.terminalFailure==nil,
      "Pausing the preview retry owner hands backoff to primary without delay or duplicate requests")
    expect(handoffOwner.result==nil,"Preview owner remains paused while primary recovers")
    handoffRetry.setPreviewReadsAllowed(true)
    expect(handoffOwner.done.wait(timeout:.now()+1) == .success
      && (handoffOwner.result ?? -1)>0 && handoffOwner.validBytes && handoffRetry.statistics.requests==2,
      "Resumed preview reads the recovered shared bytes without another download")
    handoffRetry.cancelPreview(handoffToken); handoffRetry.close()
    // Independent preview cursors share bytes and request capacity, not stop/seek.
    let scoped=client("/retry-stop?scope-test")
    expect(read(scoped,0)>0,"Prime verified primary cache")
    let previewToken=scoped.makePreviewToken(), previewWait=PendingRangeRead()
    previewWait.start(scoped,at:1048576,generation:previewToken)
    for _ in 0..<100 where scoped.statistics.recovery?.attempts.first?.plannedWait == nil || scoped.statistics.recovery?.attempts.first?.plannedWait == 0 { Thread.sleep(forTimeInterval:0.01) }
    scoped.cancelPreview(previewToken)
    expect(previewWait.done.wait(timeout:.now()+1) == .success && previewWait.result == -3,"Preview cancellation wakes only its backoff")
    expect(read(scoped,0)>0 && scoped.statistics.terminalFailure==nil,"Preview cancellation preserves primary and verified bytes")
    let exhaustedPreview=scoped.makePreviewToken()
    expect(read(scoped,2097152,4096,exhaustedPreview)<0,"Preview has bounded terminal recovery")
    expect(scoped.statistics.terminalFailure==nil && read(scoped,0)>0,"Preview exhaustion never fails primary")
    scoped.cancelPreview(exhaustedPreview); scoped.close()
    let scopes=client("/slow?scopes")
    let token=scopes.makePreviewToken()
    expect(read(scopes,0,4096,token)>0,"Preview owns independent cursor")
    scopes.changeGeneration(2)
    expect(read(scopes,16384,4096,token)>0,"Primary seek cannot cancel preview scope")
    expect(read(scopes,2097152,4096,2)>0,"Primary reads while preview is active")
    scopes.cancelPreview(token)
    expect(read(scopes,2097152,4096,2)>0,"Preview close leaves primary request intact")
    expect(read(scopes,0,4096,token)==(-3),"Closed preview scope cannot rejoin")
    scopes.close()
    let coalesced=client("/slow?shared")
    let sharing=coalesced.makePreviewToken()
    expect(read(coalesced,0,4096,sharing)>0,"Preview begins shared range")
    expect(read(coalesced,0)>0,"Primary joins same range")
    let requests=coalesced.statistics.requests
    coalesced.cancelPreview(sharing)
    expect(read(coalesced,16384)>0 && coalesced.statistics.requests==requests,"Cancellation retains coalesced primary flight")
    coalesced.close()
    let retryShare=client("/retry-503?preview-owner-cancel")
    let sharedToken=retryShare.makePreviewToken(), owner=PendingRangeRead(), follower=PendingRangeRead()
    owner.start(retryShare,at:23456,generation:sharedToken)
    for _ in 0..<100 where retryShare.statistics.recovery?.attempts.first?.plannedWait == nil || retryShare.statistics.recovery?.attempts.first?.plannedWait == 0 { Thread.sleep(forTimeInterval:0.01) }
    follower.start(retryShare,at:23456)
    for _ in 0..<100 where retryShare.statistics.coalesced<1 { Thread.sleep(forTimeInterval:0.01) }
    retryShare.cancelPreview(sharedToken)
    expect(owner.done.wait(timeout:.now()+1) == .success && owner.result == -3,"Cancelled retry owner wakes immediately")
    expect(follower.done.wait(timeout:.now()+4) == .success && (follower.result ?? -1)>0 && follower.validBytes,"Primary takes over coalesced backoff")
    expect(retryShare.statistics.requests==2 && retryShare.statistics.terminalFailure==nil,"Shared 503 uses one retry, no duplicate request or primary failure")
    retryShare.close()
    for (path,requests) in [("/retry-once",2),("/retry-twice",3),("/retry-502",2),("/retry-504",2)] {
      let c=client(path)
      expect(read(c,12345)>0,"Transient status must recover inside custom AVIO")
      expect(c.statistics.requests==requests,"Includes first request in three-attempt bound")
      expect(c.statistics.recovery?.outcome=="recovered" && c.statistics.recovery?.attempts.last?.status==206,"Recovered trace records successful attempt")
      expect(c.statistics.lastIssue==nil && c.statistics.terminalFailure==nil,"Recovered HTTP error is not current or terminal")
      expect(c.statistics.recovery?.attempts.allSatisfy { $0.offset==12345 } == true,"Retries use exact missing offset")
      c.close()
    }
    let authCap=client("/retry-auth-cap",refresh:{ source("/ok") })
    expect(read(authCap,12345)<0 && authCap.statistics.requests==3,"Authentication refresh cannot bypass total attempt cap")
    expect(authCap.statistics.refreshes==0 && authCap.statistics.recovery?.attempts.map(\.status)==[500,500,403],"Mixed failure attempts share the cap")
    authCap.close()
    let forever=client("/retry-forever"), began=Date()
    expect(read(forever,9876)<0,"Persistent 500 exhausts")
    expect(forever.statistics.requests==3 && forever.statistics.recovery?.outcome=="exhausted","Exactly three attempts before terminal failure")
    expect(forever.statistics.terminalFailure?.kind == .serverError,"500 is status failure, not malformed response")
    expect(forever.statistics.recovery?.attempts.map(\.status)==[500,500,500],"All exhausted status codes retained")
    expect(forever.statistics.memoryBytes==0 && Date().timeIntervalSince(began)<9.5,"Error body never cached; total budget bounded")
    let frozen=forever.statistics.text; forever.close()
    expect(forever.statistics.text==frozen,"Exhaustion evidence survives close")
    for path in ["/retry-503","/retry-429","/retry-date"] {
      let c=client(path)
      expect(read(c,7654)>0,"Retry-After recovers without returning premature negative")
      let attempt=c.statistics.recovery!.attempts[0]
      expect(attempt.actualWait+0.03>=attempt.plannedWait && attempt.plannedWait>=0.25,"Server delay honored")
      if path != "/retry-date" { expect(attempt.plannedWait>=1,"Delta-seconds Retry-After") }
      expect(c.statistics.requests==2,"Retry-After has bounded requests"); c.close()
    }
    let huge=client("/retry-huge"), hugeStart=Date()
    expect(read(huge,0)<0 && huge.statistics.requests==1,"Unfit Retry-After cannot be shortened into immediate retry")
    expect(Date().timeIntervalSince(hugeStart)<1 && huge.statistics.recovery?.reason=="retry-after-exceeds-budget","Huge delay does not expand budget")
    huge.close()
    let notFound=client("/retry-404")
    expect(read(notFound,0)<0 && notFound.statistics.requests==1,"404 does not retry")
    expect(notFound.statistics.terminalFailure?.kind == .httpStatus,"Non-media HTTP status is not malformed 206"); notFound.close()
    let epochDate=Date(timeIntervalSince1970:0)
    expect(RangeCoordinator.retryAfter("Thu, 01 Jan 1970 00:00:02 GMT",now:epochDate)==2,"HTTP-date parsed")
    expect(RangeCoordinator.retryAfter("-1")==nil && RangeCoordinator.retryAfter("garbage")==nil,"Invalid delay uses bounded fallback")
    for stopping in [false,true] {
      let c=client("/retry-stop?case="+UUID().uuidString), pending=PendingRangeRead()
      pending.start(c,at:2*1048576)
      for _ in 0..<300 where (c.statistics.recovery?.attempts.first?.plannedWait ?? 0)==0 { Thread.sleep(forTimeInterval:0.01) }
      expect(c.statistics.terminalFailure==nil && c.statistics.requests==1,"Backoff attempt is not terminal")
      let cancelledAt=Date()
      if stopping { c.close() } else { c.changeGeneration(2) }
      expect(pending.done.wait(timeout:.now()+1) == .success && pending.result == -3,"Stop/seek interrupts backoff promptly")
      expect(Date().timeIntervalSince(cancelledAt)<1 && c.statistics.recovery?.outcome=="cancelled","Cancellation recorded separately from exhaustion")
      expect(c.statistics.requests==1 && c.statistics.terminalFailure==nil,"No old-generation retry or terminal snapshot")
      if !stopping { expect(read(c,0,4096,2)>0,"New generation proceeds immediately") }
      c.close()
    }
    let coalescedRetry=client("/retry-503?case="+UUID().uuidString)
    let firstWaiter=PendingRangeRead(), secondWaiter=PendingRangeRead()
    firstWaiter.start(coalescedRetry,at:22222)
    for _ in 0..<200 where (coalescedRetry.statistics.recovery?.attempts.first?.plannedWait ?? 0)==0 { Thread.sleep(forTimeInterval:0.01) }
    secondWaiter.start(coalescedRetry,at:22222)
    expect(firstWaiter.done.wait(timeout:.now()+3) == .success && secondWaiter.done.wait(timeout:.now()+3) == .success,"Concurrent readers share recovery")
    expect((firstWaiter.result ?? -1)>0 && (secondWaiter.result ?? -1)>0 && firstWaiter.validBytes && secondWaiter.validBytes,"Coalesced retry returns validated bytes to both readers")
    expect(coalescedRetry.statistics.requests==2,"Only one retry owner sends a request")
    coalescedRetry.close()
    let cacheRecovery=client("/retry-cache"), cachePending=PendingRangeRead()
    expect(read(cacheRecovery,0)>0,"Seed validated cache")
    for _ in 0..<200 where cacheRecovery.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
    cachePending.start(cacheRecovery,at:2*1048576)
    for _ in 0..<200 where (cacheRecovery.statistics.recovery?.attempts.first?.plannedWait ?? 0)==0 { Thread.sleep(forTimeInterval:0.01) }
    expect(cacheRecovery.statistics.terminalFailure==nil,"500 leaves cache readable while recovering")
    expect(read(cacheRecovery,50000)>0 && cacheRecovery.statistics.memoryHitBytes>0,"Verified cache remains usable during backoff")
    expect(cachePending.done.wait(timeout:.now()+3) == .success && (cachePending.result ?? -1)>0 && cachePending.validBytes,"Uncached gap recovers independently")
    expect(cacheRecovery.statistics.lastIssue==nil && cacheRecovery.statistics.recovery?.outcome=="recovered","Recovery clears stale 500 issue")
    cacheRecovery.close()
    let retryChanged=client("/retry-version")
    expect(read(retryChanged,0)>0,"Pin version before retry")
    expect(read(retryChanged,2*1048576)==(-4),"206 after retry still must match version")
    expect(retryChanged.statistics.terminalFailure?.kind == .resourceChanged && retryChanged.statistics.recovery?.outcome=="rejected","Version conflict is not recovered")
    retryChanged.close()
    let cold=client("/ok",id:"warm",persistenceEnabled:true)
    expect(read(cold,0)>0,"206 startup")
    expect(read(cold,1040000,8576)>0,"First transfer tail")
    for _ in 0..<100 where cold.statistics.memoryBytes==0 { Thread.sleep(forTimeInterval:0.02) }
    expect(read(cold,200000)>0,"Backward cached range")
    expect(cold.statistics.memoryHitBytes>0,"Actual memory hit")
    expect(read(cold,size)==0,"Verified EOF")
    cold.close(); disk.flush()
    let warm=client("/ok",id:"warm",persistenceEnabled:true)
    expect(warm.fileSize == -1,"Listing size is not confirmed AVSEEK_SIZE")
    expect(read(warm,size-1)>0,"Warm session validates HTTP identity first")
    expect(read(warm,0)>0 && warm.statistics.diskHitBytes>0 && warm.statistics.requests==1,"Warm disk cache after validation")
    warm.close()
    let changedIdentity=client("/ok",id:"warm",version:"fixture-v2",persistenceEnabled:true)
    expect(read(changedIdentity,0)>0 && changedIdentity.statistics.requests>0,"Version isolates disk cache")
    changedIdentity.close()
    for path in ["/bad200","/wrongrange","/416"] {
      let c=client(path)
      expect(read(c,200000)<0,"Reject \(path) without false EOF/cache writes")
      expect(c.statistics.memoryBytes==0,"Rejected response cannot enter cache"); c.close()
    }
    let small=client("/small200",size:131072)
    expect(read(small,0)>0,"Bounded offset-zero 200"); small.close()
    let beyond=client("/ok",size:-1)
    expect(read(beyond,Int64.max)==0 && beyond.statistics.responses416==1,"64-bit seek verifies EOF using 416 without overflow")
    beyond.close()
    let changed=client("/changed")
    expect(read(changed,0)>0,"First validator")
    expect(read(changed,2*1048576)==(-4),"Changed ETag rejected"); changed.close()
    let refreshed=client("/expired",refresh:{ source("/ok") })
    expect(read(refreshed,0)>0 && refreshed.statistics.refreshes==1,"Single expired URL refresh"); refreshed.close()
    let redirect=client("/redirect",headers:["Authorization":"secret","Cookie":"private","X-Private":"private", "uSeR-aGeNt":"Cineva-iOS/2.0", "Referer":"https://private.invalid/?token=secret", "Origin":"https://private.invalid"])
    expect(read(redirect,0)>0,"Cross-origin redirect strips credentials"); redirect.close()
    for path in ["/short64", "/short10"] {
      let cacheID="short-warm-"+path
      let c=client(path,id:cacheID,persistenceEnabled:true)
      var offset:Int64=0
      while offset<size {
        let n=read(c,offset,65536)
        expect(n>0,"Short 206 continues from actual coverage at \(offset)")
        offset+=Int64(n)
      }
      expect(read(c,size)==0,"Short 206 verified EOF")
      expect(read(c,7777)>0 && read(c,2*1048576+37)>0,"Short 206 backward/random reads")
      expect(c.statistics.requests<400,"Short 206 finite request count")
      for _ in 0..<100 where c.statistics.memoryBytes<Int(size) { Thread.sleep(forTimeInterval:0.01) }
      c.close(); disk.flush()
      let warmShort=client(path,id:cacheID,persistenceEnabled:true)
      expect(read(warmShort,size-1)>0 && read(warmShort,0)>0,"Short 206 warm validation/read")
      expect(warmShort.statistics.diskHitBytes>0,"Only assembled complete short-response pages persist")
      warmShort.close()
    }
    for hint in [size-1,size+1] {
      let c=client("/ok",size:hint,id:"warm",persistenceEnabled:true)
      expect(c.fileSize == -1,"Provisional size unavailable to AVSEEK_SIZE")
      expect(read(c,hint)<0 && c.statistics.requests==1,"Hint cannot manufacture EOF")
      expect(c.statistics.terminalFailure?.kind == .metadataConflict,"Hint mismatch classified without mixing cache")
      expect(c.statistics.diskHitBytes==0 && c.statistics.memoryBytes==0,"Hint conflict isolates existing pages")
      let frozen=c.statistics.terminalFailure!.text
      c.close()
      expect(c.statistics.terminalFailure?.text==frozen,"Teardown preserves first terminal evidence")
    }
    let direct=client("/ok",cacheEnabled:false)
    expect(read(direct,0)>0,"Direct AVIO reads real bytes")
    expect(read(direct,2*1048576)>0 && read(direct,0)>0,"Direct AVIO forward/backward input")
    expect(direct.statistics.memoryHitBytes==0 && direct.statistics.diskHitBytes==0 && direct.statistics.memoryBytes==0,"Direct AVIO bypasses all pages")
    expect(direct.statistics.requests>=3,"Direct backread actually uses transport")
    direct.close()
    for path in ["/badlength","/shortchange","/missingetag"] {
      let c=client(path)
      if path != "/badlength" { expect(read(c,0)>0,"Initial matching representation") }
      let offset:Int64=path == "/shortchange" ? 10000 : 2*1048576
      expect(read(c,offset)<0,"Reject invalid body declaration or version loss")
      expect(c.statistics.terminalFailure != nil,"Typed terminal snapshot retained")
      c.close()
    }
    for path in ["/overbody","/underbody"] {
      let c=client(path)
      expect(read(c,0) != 0,"Malformed body never false EOF")
      for _ in 0..<100 where c.statistics.terminalFailure==nil { Thread.sleep(forTimeInterval:0.01) }
      expect(c.statistics.terminalFailure?.kind == .malformedResponse,"Chunked body length validated on completion")
      expect(c.statistics.memoryBytes==0 && read(c,9999)<0,"Malformed body cannot persist a page")
      c.close()
    }
    let sparse=client("/short10")
    for offset in [Int64(32000),0,15000,65530,999999,2000000,10000] {
      expect(read(sparse,offset,12000)>0,"Sparse holes must fetch real coverage, never zero-fill")
    }
    sparse.close()
    let newHTTPVersion=client("/v2",id:"warm",persistenceEnabled:true)
    expect(read(newHTTPVersion,size-1)>0 && read(newHTTPVersion,0)>0,"New HTTP version independently validates")
    expect(newHTTPVersion.statistics.diskHitBytes==0,"Changed HTTP ETag cannot reuse old version disk pages")
    newHTTPVersion.close()
    let noValidator=client("/novalidator")
    expect(read(noValidator,0)>0 && read(noValidator,2*1048576)>0,"No-validator source still streams")
    expect(noValidator.statistics.memoryBytes==0 && noValidator.statistics.diskHitBytes==0,"No-validator responses never merge cached fragments")
    noValidator.close()
    let auth=client("/expired",headers:["Authorization":"do-not-log", "User-Agent":"Cineva-iOS/2.0"])
    expect(read(auth,0)<0 && auth.statistics.terminalFailure?.kind == .authentication,"Authentication is typed")
    let evidence=auth.statistics.terminalFailure!.text
    auth.close()
    expect(!evidence.contains("do-not-log") && !evidence.contains("http") && !evidence.contains("Authorization"),"Evidence has no credentials or URL")
    expect(auth.statistics.terminalFailure?.text==evidence,"Close cannot replace failure with cancellation")
    let slow=client("/slow"), before=Date()
    expect(read(slow,0)>0 && Date().timeIntervalSince(before)<1,"Incremental bytes before full block")
    slow.changeGeneration(2)
    expect(read(slow,0,4096,1)==(-3),"Stale seek generation cancelled")
    expect(read(slow,2*1048576,4096,2)>0,"New seek progresses"); slow.close()
    let cut=client("/cut")
    // CFNetwork may report a truncated response before delivering its prefix.
    // Both a verified prefix and a bounded I/O error are correct; false EOF is not.
    expect(read(cut,0) != 0,"Disconnect is never a false EOF")
    expect(read(cut,500000)<0,"Truncation bounded failure"); cut.close()
    let timeout=client("/timeout")
    expect(read(timeout,0)<0,"Timeout bounded failure"); timeout.close()
    expect(RangeCoordinator.contentRange("bytes 5-4/9")==nil,"Invalid range")
    expect(RangeCoordinator.contentRange("bytes 0-9/9")==nil,"End outside total")
    expect(RangeCoordinator.contentRange("bytes -1-5/9")==nil,"Negative syntax is not silently stripped")
    expect(RangeCoordinator.contentRange("bytes +0-5/9")==nil,"Range requires decimal digits")
    let diskGate=SlowDiskGate()
    let blockedDisk=SegmentDiskCache(root:root.appendingPathComponent("blocked-writer"),
      freeSpace:{ diskGate.available() })
    let whileWriting=RangeCoordinator(source:source("/large"),identity:RangeCacheIdentity(
      account:"test",fileID:"blocked-writer",size:576*1048576+97,validator:"test-v1"),disk:blockedDisk,persistenceEnabled:true)
    expect(read(whileWriting,0)>0,"First bytes precede disk persistence")
    expect(diskGate.entered.wait(timeout:.now()+2) == .success,"Fixture holds actual utility writer")
    expect(!whileWriting.mediaCacheProgress.complete && whileWriting.mediaCacheProgress.bytes==0,
      "Network completion and pending writes never count as durable complete coverage")
    // The shipping default must not even join the disk utility queue. A writer
    // from an earlier session is deliberately held while a new stream opens.
    let streamingStarted=ProcessInfo.processInfo.systemUptime
    let independentStream=RangeCoordinator(source:source("/large"),identity:RangeCacheIdentity(
      account:"test",fileID:"streaming-beside-writer",size:576*1048576+97,validator:"test-v1"),disk:blockedDisk)
    expect(ProcessInfo.processInfo.systemUptime-streamingStarted<0.5,
      "Default streaming construction does not wait behind disk persistence")
    expect(read(independentStream,0)>0 && independentStream.statistics.requests==1,
      "Default streaming starts through real network while the disk writer is blocked")
    expect(independentStream.statistics.diskHitBytes==0 && independentStream.mediaCacheProgress.bytes==0,
      "Default streaming cannot claim disk hits or whole-file cache completion")
    independentStream.close()
    let duringWrite=ProcessInfo.processInfo.systemUptime
    expect(read(whileWriting,2*1048576)>0,"Foreground miss progresses with disk writer blocked")
    expect(ProcessInfo.processInfo.systemUptime-duringWrite<1,"Disk callback cannot delay foreground network read")
    for index in 3..<12 {
      expect(read(whileWriting,Int64(index)*1048576)>0,"Network stays usable under disk backpressure")
      for _ in 0..<100 where whileWriting.statistics.memoryBytes<(index-1)*1048576 { Thread.sleep(forTimeInterval:0.005) }
      expect(blockedDisk.queuedWriteBytes<=4*1048576,"Pending persistence never exceeds 4 MiB")
    }
    diskGate.release.signal(); whileWriting.close(); blockedDisk.flush()
    let priority=client("/slow?priority",persistenceEnabled:true)
    expect(read(priority,0)>0,"Prime foreground before prefetch priority check")
    for _ in 0..<400 where priority.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
    priority.allowPrefetch(true)
    for _ in 0..<400 where priority.statistics.requests<2 { Thread.sleep(forTimeInterval:0.01) }
    expect(priority.statistics.requests==2,"Independent prefetch begins without decoder reads")
    let priorityAt=ProcessInfo.processInfo.systemUptime
    priority.changeGeneration(2)
    expect(read(priority,2*1048576,4096,2)>0,"Final seek preempts unrelated slow prefetch")
    expect(ProcessInfo.processInfo.systemUptime-priorityAt<1,"Speculative range cannot occupy foreground seek slot")
    expect(read(priority,0,4096,2)>0,"Seek retains completed head bytes")
    priority.close()
    let resumeRoot=root.appendingPathComponent("resume")
    let resumeDisk=SegmentDiskCache(root:resumeRoot)
    let resumeIdentity=RangeCacheIdentity(account:"resume",fileID:"movie",size:size,
      validator:"sha1:"+String(repeating:"b",count:40))
    let partial=RangeCoordinator(source:source("/ok"),identity:resumeIdentity,disk:resumeDisk,persistenceEnabled:true)
    expect(read(partial,0)>0,"Prime persistent partial media")
    for _ in 0..<400 where partial.mediaCacheProgress.bytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
    expect(partial.mediaCacheProgress.bytes==1048576,"Partial reopen fixture waits for durable head pages")
    partial.close(); resumeDisk.flush()
    let resumedDisk=SegmentDiskCache(root:resumeRoot)
    expect(resumedDisk.restored(identity:resumeIdentity.key)?.complete==false,"Partial manifest is not complete")
    let resumed=RangeCoordinator(source:source("/ok"),identity:resumeIdentity,disk:resumedDisk,persistenceEnabled:true)
    expect(read(resumed,0)>0 && resumed.statistics.requests==0,"Partial reopen serves verified old head without redownload")
    var diskReadiness=CachedSeekReadiness(); diskReadiness.begin(generation:1)
    diskReadiness.observe(resumed.playbackReadState,buffering:true)
    expect(!diskReadiness.needsNetwork && resumed.statistics.diskHitBytes>0,
      "Partial durable cache hit suppresses seek buffering just like a memory hit")
    resumed.allowPrefetch(true)
    for _ in 0..<200 where !resumed.mediaCacheProgress.complete { Thread.sleep(forTimeInterval:0.05) }
    expect(resumed.mediaCacheProgress.complete && resumed.statistics.networkBytes==size-1048576,"Resume fills only persistent gaps")
    resumed.close()
    let reducedQuota=SegmentDiskCache(root:resumeRoot,capacity:{ 1048576 })
    let completedUnderQuota=reducedQuota.inspect(key:resumeIdentity.key,identity:resumeIdentity.key,
      total:size,validator:"\"v1\"",persistent:true,reserveWhole:true).0
    expect(completedUnderQuota.complete && completedUnderQuota.limitation==nil,"Lowering quota cannot mislabel an already complete file as a paused download")
    // Retain a completed unaligned seek flight while its partial memory pages
    // age out of the 32 MiB LRU. Gap fill must reassemble the old flight's tail.
    let fragmentSize:Int64=40*1048576+97
    let fragment=client("/fragment",size:fragmentSize,persistenceEnabled:true)
    expect(read(fragment,34*1048576+123)>0,"Unaligned seek seeds partial page boundaries")
    for _ in 0..<200 where fragment.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
    fragment.allowPrefetch(true)
    for _ in 0..<900 where !fragment.mediaCacheProgress.complete { Thread.sleep(forTimeInterval:0.05) }
    print("FRAGMENT_CACHE bytes=\(fragment.mediaCacheProgress.bytes) network=\(fragment.statistics.networkBytes)"); fflush(stdout)
    expect(fragment.mediaCacheProgress.complete,"Evicted partial flight fragments must join durable coverage, not loop forever")
    expect(fragment.statistics.networkBytes<=fragmentSize+131072,"Retained/durable spans are not downloaded repeatedly")
    fragment.close()
    // Real disk and local HTTP, >512 MiB. No playback reads are used to drive
    // completion after the initial/seek windows: this models same-page pause.
    let largeSize:Int64=576*1048576+97
    let largeRoot=root.appendingPathComponent("large")
    let largeDisk=SegmentDiskCache(root:largeRoot,capacity:{ 2*1073741824 },freeSpace:{ 8*1073741824 })
    let identity=RangeCacheIdentity(account:"large-test",fileID:"movie",size:largeSize,
      validator:"sha1:"+String(repeating:"a",count:40))
    let large=RangeCoordinator(source:source("/large"),identity:identity,disk:largeDisk,persistenceEnabled:true)
    let coldAt=ProcessInfo.processInfo.systemUptime
    expect(read(large,0)>0,"Large file starts incrementally")
    let coldMS=(ProcessInfo.processInfo.systemUptime-coldAt)*1000
    for _ in 0..<200 where large.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
    let warmAt=ProcessInfo.processInfo.systemUptime
    expect(read(large,12345)>0,"Seek cached head")
    let warmMS=(ProcessInfo.processInfo.systemUptime-warmAt)*1000
    large.changeGeneration(2)
    let seekAt=ProcessInfo.processInfo.systemUptime
    expect(read(large,350*1048576+123,4096,2)>0,"Uncached final seek gets foreground request")
    let seekMS=(ProcessInfo.processInfo.systemUptime-seekAt)*1000
    for _ in 0..<200 where large.statistics.memoryBytes<2*1048576 { Thread.sleep(forTimeInterval:0.01) }
    large.allowPrefetch(true)
    let fillStarted=ProcessInfo.processInfo.systemUptime
    let completionDeadline=fillStarted+600
    var previous:Int64=0,lastReported:Int64=0
    var lastGrowth=fillStarted
    while !large.mediaCacheProgress.complete && ProcessInfo.processInfo.systemUptime<completionDeadline {
      Thread.sleep(forTimeInterval:0.2)
      let progress=large.mediaCacheProgress
      expect(progress.bytes>=previous,"Active file cannot self-evict earlier pages")
      if progress.bytes>previous { lastGrowth=ProcessInfo.processInfo.systemUptime }
      if progress.bytes-lastReported>=64*1048576 || ProcessInfo.processInfo.systemUptime-lastGrowth>30 {
        print("WHOLE_CACHE bytes=\(progress.bytes)/\(largeSize) network=\(large.statistics.networkBytes) requests=\(large.statistics.requests) pending=\(largeDisk.queuedWriteBytes) elapsed=\(ProcessInfo.processInfo.systemUptime-fillStarted)"); fflush(stdout)
        lastReported=progress.bytes
      }
      expect(ProcessInfo.processInfo.systemUptime-lastGrowth<30,"Whole-file fill must keep making durable progress")
      previous=progress.bytes
      expect(large.statistics.memoryBytes<=32*1048576,"Whole-file fill has bounded memory")
      if let problem=progress.limitation { preconditionFailure(problem) }
    }
    print("WHOLE_CACHE final=\(large.mediaCacheProgress) network=\(large.statistics.networkBytes) elapsed=\(ProcessInfo.processInfo.systemUptime-fillStarted)"); fflush(stdout)
    expect(large.mediaCacheProgress.complete && large.mediaCacheProgress.bytes==largeSize,"Paused prefetch passes 512 MiB and completes every byte")
    expect(large.statistics.networkBytes<=largeSize+2*1048576,"Gap fill does not redownload cached ranges")
    large.close(); largeDisk.flush()
    let reopenedDisk=SegmentDiskCache(root:largeRoot,capacity:{ 2*1073741824 },freeSpace:{ 8*1073741824 })
    expect(reopenedDisk.restored(identity:identity.key)?.complete==true,"Persisted identity, length and complete coverage survive reopening")
    // An unreachable URL proves neither URL refresh nor remote I/O is required.
    let offline=RangeCoordinator(source:source("/expired"),identity:identity,disk:reopenedDisk,persistenceEnabled:true)
    for offset in [Int64(0),largeSize/2,largeSize-4096] { expect(read(offline,offset)>0,"Offline head/middle/tail bytes") }
    expect(offline.statistics.requests==0 && offline.statistics.diskHitBytes>0,"Fully cached AVIO never opens network")
    offline.close()
    let onlineOnly=RangeCoordinator(source:source("/expired"),identity:identity,disk:reopenedDisk)
    expect(onlineOnly.fileSize == -1 && read(onlineOnly,0)<0 && onlineOnly.statistics.requests==1
      && onlineOnly.statistics.diskHitBytes==0 && !onlineOnly.mediaCacheProgress.complete,
      "Default streaming ignores an actually complete legacy cache and requires valid network input")
    onlineOnly.close()
    let block=largeRoot.appendingPathComponent("\(identity.key)-0.block")
    var corrupt=try Data(contentsOf:block); corrupt[40] ^= 0xff; try corrupt.write(to:block,options:.atomic)
    let checkedDisk=SegmentDiskCache(root:largeRoot)
    expect(checkedDisk.restored(identity:identity.key)?.complete==false,"Corruption invalidates complete coverage, no historical maximum")
    expect(checkedDisk.read(key:identity.key,offset:0,length:65536)==nil,"Corrupt page is never served")
    for lowSpace in [false,true] {
      let limitedDisk=SegmentDiskCache(root:root.appendingPathComponent(UUID().uuidString),
        capacity:{ lowSpace ? 2*1073741824 : 8*1048576 },freeSpace:{ lowSpace ? 1073741824+2*1048576 : 8*1073741824 })
      let limited=RangeCoordinator(source:source("/large"),identity:identity,disk:limitedDisk,persistenceEnabled:true)
      expect(read(limited,0)>0,"Limited capacity still streams normally")
      limited.allowPrefetch(true)
      for _ in 0..<100 where limited.mediaCacheProgress.limitation==nil { Thread.sleep(forTimeInterval:0.05) }
      expect(limited.mediaCacheProgress.limitation != nil,"Insufficient quota/free space is visible")
      let count=limited.statistics.requests; Thread.sleep(forTimeInterval:0.5)
      expect(limited.statistics.requests==count,"No speculative download when whole file cannot fit")
      expect(read(limited,10*1048576)>0,"Foreground seek survives insufficient cache capacity")
      limited.close()
    }
    print(String(format:"Local HTTP byte-read timing only: cold %.2f ms; cached seek %.2f ms; uncached seek %.2f ms",coldMS,warmMS,seekMS))
    let epoch=disk.epoch
    disk.clear()
    disk.write(Data([1,2,3]),key:"old",offset:0,epoch:epoch)
    expect(disk.read(key:"old",offset:0,length:3)==nil,"Old download cannot repopulate cleared disk")
    disk.write(Data([1,2,3]),key:"new",offset:0,epoch:disk.epoch)
    expect(disk.read(key:"new",offset:0,length:3)==Data([1,2,3]),"New cache epoch accepts writes")
    print("Range transport checks passed: \(checks)")
  }
}
