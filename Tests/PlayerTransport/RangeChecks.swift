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
                version: String = "fixture-v1", headers: [String:String] = [:], refresh: RangeCoordinator.Refresh? = nil) -> RangeCoordinator {
      RangeCoordinator(source:source(path,headers:headers),identity:RangeCacheIdentity(account:"test-account",fileID:id,size:size,validator:version),disk:disk,refresh:refresh)
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
    expect(read(warm,0)>0 && warm.statistics.diskHitBytes>0 && warm.statistics.requests==0,"Warm disk cache")
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
      let c=client(path)
      var offset:Int64=0
      while offset<size {
        let n=read(c,offset,65536)
        expect(n>0,"Short 206 continues from actual coverage at \(offset)")
        offset+=Int64(n)
      }
      expect(read(c,size)==0,"Short 206 verified EOF")
      expect(read(c,7777)>0 && read(c,2*1048576+37)>0,"Short 206 backward/random reads")
      expect(c.statistics.requests<400,"Short 206 finite request count")
      c.close()
    }
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
    let epoch=disk.epoch
    disk.clear()
    disk.write(Data([1,2,3]),key:"old",offset:0,epoch:epoch)
    expect(disk.read(key:"old",offset:0,length:3)==nil,"Old download cannot repopulate cleared disk")
    disk.write(Data([1,2,3]),key:"new",offset:0,epoch:disk.epoch)
    expect(disk.read(key:"new",offset:0,length:3)==Data([1,2,3]),"New cache epoch accepts writes")
    print("Range transport checks passed: \(checks)")
  }
}
