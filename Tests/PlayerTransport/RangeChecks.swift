import Foundation

private final class PendingRangeRead: @unchecked Sendable {
  let done=DispatchSemaphore(value:0)
  private let lock=NSLock()
  private var value:Int32?
  private var integrity=true
  var result:Int32? { lock.lock(); defer { lock.unlock() }; return value }
  var validBytes:Bool { lock.lock(); defer { lock.unlock() }; return integrity }
  func start(_ client:RangeCoordinator,at offset:Int64,generation:Int32 = 1) {
    DispatchQueue.global().async {
      var bytes=[UInt8](repeating:0,count:4096)
      let n=client.read(offset:offset,buffer:&bytes,count:4096,generation:generation)
      let valid=n<=0 || (0..<Int(n)).allSatisfy { bytes[$0]==UInt8((offset+Int64($0))%251) }
      self.lock.lock(); self.value=n; self.integrity=valid; self.lock.unlock(); self.done.signal()
    }
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
                version: String = "fixture-v1", cacheEnabled: Bool = true, headers: [String:String] = [:], refresh: RangeCoordinator.Refresh? = nil) -> RangeCoordinator {
      RangeCoordinator(source:source(path,headers:headers),identity:RangeCacheIdentity(account:"test-account",fileID:id,size:size,validator:version),disk:disk,cacheEnabled:cacheEnabled,refresh:refresh)
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
    let cold=client("/ok",id:"warm")
    expect(read(cold,0)>0,"206 startup")
    expect(read(cold,1040000,8576)>0,"First transfer tail")
    for _ in 0..<100 where cold.statistics.memoryBytes==0 { Thread.sleep(forTimeInterval:0.02) }
    expect(read(cold,200000)>0,"Backward cached range")
    expect(cold.statistics.memoryHitBytes>0,"Actual memory hit")
    expect(read(cold,size)==0,"Verified EOF")
    cold.close()
    let warm=client("/ok",id:"warm")
    expect(warm.fileSize == -1,"Listing size is not confirmed AVSEEK_SIZE")
    expect(read(warm,size-1)>0,"Warm session validates HTTP identity first")
    expect(read(warm,0)>0 && warm.statistics.diskHitBytes>0 && warm.statistics.requests==1,"Warm disk cache after validation")
    warm.close()
    let changedIdentity=client("/ok",id:"warm",version:"fixture-v2")
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
      let c=client(path,id:cacheID)
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
      c.close()
      let warmShort=client(path,id:cacheID)
      expect(read(warmShort,size-1)>0 && read(warmShort,0)>0,"Short 206 warm validation/read")
      expect(warmShort.statistics.diskHitBytes>0,"Only assembled complete short-response pages persist")
      warmShort.close()
    }
    for hint in [size-1,size+1] {
      let c=client("/ok",size:hint,id:"warm")
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
    let newHTTPVersion=client("/v2",id:"warm")
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
    let epoch=disk.epoch
    disk.clear()
    disk.write(Data([1,2,3]),key:"old",offset:0,epoch:epoch)
    expect(disk.read(key:"old",offset:0,length:3)==nil,"Old download cannot repopulate cleared disk")
    disk.write(Data([1,2,3]),key:"new",offset:0,epoch:disk.epoch)
    expect(disk.read(key:"new",offset:0,length:3)==Data([1,2,3]),"New cache epoch accepts writes")
    print("Range transport checks passed: \(checks)")
  }
}
