import Foundation
import UIKit
import XCTest
@testable import CinevaCacheValidation

final class ArtworkSchedulingTests: XCTestCase {
  private var root:URL!
  private var disk:ArtworkDiskStore!
  override func setUpWithError() throws {
    root=FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkScheduling-"+UUID().uuidString)
    disk=ArtworkDiskStore(directory:root.appendingPathComponent("artwork"),legacyDirectory:root.appendingPathComponent("old"))
  }
  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) }
  }
  private func item(_ id:String)->CloudItem {
    CloudItem(id:id,parentID:"root",name:id+".mp4",isDirectory:false,pickCode:id,sha1:id,size:1024,
      fileExtension:"mp4",isVideo:true,duration:0,thumbnailURLString:nil,modifiedAt:Date(timeIntervalSince1970:1000))
  }
  private func image()->UIImage {
    UIGraphicsImageRenderer(size:CGSize(width:32,height:18)).image { context in
      UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:32,height:18))
    }
  }
  private func waitForQueue(_ cache:ThumbnailService,visible:Int,prefetch:Int) async {
    for _ in 0..<200 {
      let counts=await cache.queuedRequestCounts()
      if counts.visible==visible && counts.prefetch==prefetch { return }
      try? await Task.sleep(nanoseconds:5_000_000)
    }
    XCTFail("Artwork queue did not reach visible=\(visible), prefetch=\(prefetch)")
  }
  private func waitForFrames(_ gate:SchedulingFrameGate,count:Int) async {
    for _ in 0..<200 {
      let calls=await gate.totalCalls
      if calls>=count { return }
      try? await Task.sleep(nanoseconds:5_000_000)
    }
    XCTFail("Frame loader did not start \(count) requests")
  }

  func testCancelledVisibleConsumersReturnQueuedWorkToPrefetchQuota() async {
    let ready=image(),gate=SchedulingFrameGate(image:image()),api=APIClient()
    let cache=ThumbnailService(disk:disk,namespace:{ "test" },loader:{ _,_ in nil },
      frameLoader:{ item,_ in
        if item.id=="visible-C" { return ready }
        return await gate.load(item.id)
      })
    let owner=UUID()
    await cache.suspendNetwork(for:owner)
    let a=item("A"),b=item("B")
    let backgroundA=Task { await cache.thumbnail(for:a,api:api,isPrefetch:true) }
    let backgroundB=Task { await cache.thumbnail(for:b,api:api,isPrefetch:true) }
    await waitForQueue(cache,visible:0,prefetch:2)
    let visibleA=Task { await cache.thumbnail(for:a,api:api) }
    let visibleB=Task { await cache.thumbnail(for:b,api:api) }
    await waitForQueue(cache,visible:2,prefetch:0)
    visibleA.cancel(); visibleB.cancel()
    let abandonedA=await visibleA.value,abandonedB=await visibleB.value
    XCTAssertNil(abandonedA); XCTAssertNil(abandonedB)
    await waitForQueue(cache,visible:0,prefetch:2)
    await cache.resumeNetwork(for:owner)
    await waitForFrames(gate,count:1)
    await waitForQueue(cache,visible:0,prefetch:1)
    let backgroundCount=await gate.totalCalls
    XCTAssertEqual(backgroundCount,1,"Only one background frame may occupy the two-frame pool")
    let delivered=expectation(description:"New visible frame has a free lane")
    let c=item("visible-C")
    let visibleC=Task {
      let result=await cache.thumbnail(for:c,api:api)
      XCTAssertNotNil(result); delivered.fulfill(); return result
    }
    await fulfillment(of:[delivered],timeout:2)
    await gate.release()
    _=await visibleC.value; _=await backgroundA.value; _=await backgroundB.value
    await cache.flushPersistence()
  }

  func testActivePromotionFreesPrefetchQuotaAndSharedCancellationKeepsVisibleWork() async {
    let gate=SchedulingFrameGate(image:image()),api=APIClient()
    let cache=ThumbnailService(disk:disk,namespace:{ "test" },loader:{ _,_ in nil },
      frameLoader:{ item,_ in await gate.load(item.id) })
    let a=item("A"),b=item("B")
    let backgroundA=Task { await cache.thumbnail(for:a,api:api,isPrefetch:true) }
    await waitForFrames(gate,count:1)
    let visibleA=Task { await cache.thumbnail(for:a,api:api) }
    let backgroundB=Task { await cache.thumbnail(for:b,api:api,isPrefetch:true) }
    await waitForFrames(gate,count:2)
    backgroundA.cancel()
    let abandoned=await backgroundA.value
    XCTAssertNil(abandoned)
    await gate.release()
    let visible=await visibleA.value,background=await backgroundB.value
    XCTAssertNotNil(visible); XCTAssertNotNil(background)
    let aCalls=await gate.calls(for:"A")
    XCTAssertEqual(aCalls,1,"Cancelling the speculative consumer cannot restart or kill shared visible work")
    await cache.flushPersistence()
  }

  func testLastVisibleCancellationYieldsAnExcessActiveBackgroundFrame() async {
    let ready=image(),gate=SchedulingFrameGate(image:image()),api=APIClient()
    let cache=ThumbnailService(disk:disk,namespace:{ "test" },loader:{ _,_ in nil },
      frameLoader:{ item,_ in
        if item.id=="visible-C" { return ready }
        return await gate.load(item.id)
      })
    let a=item("A"),b=item("B")
    let backgroundA=Task { await cache.thumbnail(for:a,api:api,isPrefetch:true) }
    await waitForFrames(gate,count:1)
    let visibleA=Task { await cache.thumbnail(for:a,api:api) }
    let backgroundB=Task { await cache.thumbnail(for:b,api:api,isPrefetch:true) }
    await waitForFrames(gate,count:2)
    visibleA.cancel()
    let abandoned=await visibleA.value
    XCTAssertNil(abandoned)
    let delivered=expectation(description:"Downgraded frame yields to current visible card")
    let c=item("visible-C")
    let visibleC=Task {
      let result=await cache.thumbnail(for:c,api:api)
      XCTAssertNotNil(result); delivered.fulfill(); return result
    }
    await fulfillment(of:[delivered],timeout:2)
    await gate.release()
    _=await visibleC.value; _=await backgroundA.value; _=await backgroundB.value
    await cache.flushPersistence()
  }
}

private actor SchedulingFrameGate {
  let image:UIImage
  private var counts:[String:Int]=[:]
  private var continuations:[CheckedContinuation<Void,Never>]=[]
  private var released=false
  init(image:UIImage) { self.image=image }
  var totalCalls:Int { counts.values.reduce(0,+) }
  func calls(for id:String)->Int { counts[id,default:0] }
  func load(_ id:String) async->UIImage? {
    counts[id,default:0]+=1
    if !released { await withCheckedContinuation { continuations.append($0) } }
    return image
  }
  func release() {
    released=true
    let waiting=continuations; continuations.removeAll()
    for continuation in waiting { continuation.resume() }
  }
}
