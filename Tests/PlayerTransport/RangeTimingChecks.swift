import Foundation

// Same public AVIO calls compiled against both the pre-change and current source.
// This measures loopback byte delivery, NOT first rendered frame or audible sound.
@main struct RangeTimingChecks {
  static func main() {
    let base=CommandLine.arguments[1], label=CommandLine.arguments[2]
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let disk=SegmentDiskCache(root:root), size:Int64=3*1048576+97
    var cold:[Double]=[],warm:[Double]=[],cachedSeek:[Double]=[],missSeek:[Double]=[]
    var warmRequests:[Int]=[]
    func read(_ client:RangeCoordinator,_ offset:Int64,_ generation:Int32 = 1)->Double {
      var bytes=[UInt8](repeating:0,count:4096)
      let start=ProcessInfo.processInfo.systemUptime
      let count=client.read(offset:offset,buffer:&bytes,count:4096,generation:generation)
      precondition(count>0 && (0..<Int(count)).allSatisfy { bytes[$0]==UInt8((offset+Int64($0))%251) })
      return (ProcessInfo.processInfo.systemUptime-start)*1000
    }
    for run in 0..<7 {
      let source=VideoSource(id:"timing",title:"timing",definition:0,
        url:URL(string:base+"/ok")!,kind:.original,headers:[:])
      let identity=RangeCacheIdentity(account:"benchmark",fileID:String(run),size:size,
        validator:"sha1:"+String(repeating:"d",count:40))
      let start=ProcessInfo.processInfo.systemUptime
      let first=RangeCoordinator(source:source,identity:identity,disk:disk)
      _=read(first,0); cold.append((ProcessInfo.processInfo.systemUptime-start)*1000)
      for _ in 0..<200 where first.statistics.memoryBytes<1048576 { Thread.sleep(forTimeInterval:0.01) }
      cachedSeek.append(read(first,65536))
      first.changeGeneration(2); missSeek.append(read(first,2*1048576,2))
      for _ in 0..<200 where first.statistics.memoryBytes<2*1048576 { Thread.sleep(forTimeInterval:0.01) }
      // The baseline reuses disk; current streaming intentionally reopens via
      // HTTP. Report request counts rather than calling this an offline warm hit.
      Thread.sleep(forTimeInterval:0.1)
      first.close()
      let reopened=ProcessInfo.processInfo.systemUptime
      let second=RangeCoordinator(source:source,identity:identity,disk:disk)
      _=read(second,0); warm.append((ProcessInfo.processInfo.systemUptime-reopened)*1000)
      warmRequests.append(second.statistics.requests); second.close()
    }
    func report(_ name:String,_ samples:[Double]) {
      let sorted=samples.sorted()
      print(String(format:"AVIO_BENCH %@ %@ n=%d median_ms=%.3f max_ms=%.3f",label,name,samples.count,sorted[sorted.count/2],sorted.last!))
    }
    report("cold",cold); report("reopen",warm); report("memory_seek",cachedSeek); report("network_seek",missSeek)
    print("AVIO_BENCH \(label) reopen_requests=\(warmRequests)")
  }
}
