import Foundation

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
