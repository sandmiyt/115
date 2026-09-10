import AVFoundation
import UIKit
import XCTest
@testable import CinevaCacheValidation

final class ArtworkCacheTests: XCTestCase {
  func testDeadlineReturnsWithoutWaitingForUncooperativeLoader() async {
    let held = HeldLoader(image: image())
    let returned = expectation(description: "deadline returns while loader is held")
    let task = Task {
      let result = await ThumbnailService.boundedArtwork(seconds: 0.1) { await held.load() }
      XCTAssertNil(result)
      returned.fulfill()
    }
    await fulfillment(of: [returned], timeout: 2)
    await held.finish()
    await task.value
  }

  func testCancellationReturnsWithoutWaitingForUncooperativeLoader() async {
    let held = HeldLoader(image: image())
    let returned = expectation(description: "cancellation returns while loader is held")
    let task = Task {
      let result = await ThumbnailService.boundedArtwork(seconds: 30) { await held.load() }
      XCTAssertNil(result)
      returned.fulfill()
    }
    for _ in 0..<100 {
      let started = await held.started
      if started { break }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    task.cancel()
    await fulfillment(of: [returned], timeout: 2)
    await held.finish()
    await task.value
  }

  func testReadyArtworkDoesNotWaitForSlowAlternative() async {
    let ready = image()
    let gate = FrameGate(image: ready)
    let returned = expectation(description: "ready poster wins without waiting for server")
    let task = Task {
      let result = await ThumbnailService.firstAvailableArtwork([
        { await gate.load() }, { ready }
      ])
      XCTAssertNotNil(result)
      returned.fulfill()
    }
    await fulfillment(of: [returned], timeout: 2)
    await gate.release()
    await task.value
  }

  func testMissingCandidateDoesNotDiscardLaterArtwork() async {
    let ready = image()
    let result = await ThumbnailService.firstAvailableArtwork([
      { nil },
      {
        try? await Task.sleep(nanoseconds: 20_000_000)
        return ready
      }
    ])
    XCTAssertNotNil(result)
    let empty = await ThumbnailService.firstAvailableArtwork([{ nil }, { nil }])
    XCTAssertNil(empty)
  }

  func testExistingLargeVideoCoverIsDownsampledOnDiskCacheRead() async throws {
    let video = item()
    let large = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }
    let data = try XCTUnwrap(large.jpegData(compressionQuality: 0.8))
    try disk.write(data, for: identity(video))
    let cache = ThumbnailService(disk: disk, namespace: { "mount-a" })
    let loaded = await cache.thumbnail(for: video, api: APIClient())
    let cover = try XCTUnwrap(loaded)
    XCTAssertLessThanOrEqual(cover.size.width * cover.scale, 640)
    XCTAssertGreaterThan(cover.size.width * cover.scale, 0)
  }

  func testLocalWarmupMakesCoverAvailableWithoutAnAsyncViewRequest() async throws {
    let video = item()
    let data = try XCTUnwrap(image().jpegData(compressionQuality: 0.8))
    try disk.write(data, for: identity(video))
    let cache = ThumbnailService(disk: disk, namespace: { "mount-a" }, loader: { _, _ in
      XCTFail("Cache warmup must not request the network")
      return nil
    })
    XCTAssertNil(cache.cachedThumbnail(for: video))
    await cache.warmLocalThumbnails([video])
    XCTAssertNotNil(cache.cachedThumbnail(for: video))
    _ = await cache.clearCache()
    XCTAssertNil(cache.cachedThumbnail(for: video))
  }

  func testLatePlaybackAcquireCannotCloseAnAlreadyReleasedGate() async {
    let cache = service(LoadProbe(image: image()))
    let owner = UUID()
    await cache.resumeNetwork(for: owner)
    await cache.suspendNetwork(for: owner)
    let completed = expectation(description: "late owner does not trap directory requests")
    let task = Task {
      let result = await cache.thumbnail(for: item(), api: APIClient())
      XCTAssertNotNil(result)
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 2)
    task.cancel()
    await task.value
  }

  private var root: URL!
  private var disk: ArtworkDiskStore!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("CinevaCacheTests-" + UUID().uuidString)
    disk = ArtworkDiskStore(directory: root.appendingPathComponent("Persistent"),
                            legacyDirectory: root.appendingPathComponent("Caches/GeneratedThumbnails"))
  }

  override func tearDownWithError() throws {
    if let root, FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

  private func item(_ id: String = "/115/movie.mp4", etag: String = "etag-a",
                    size: Int64 = 1024, date: Double = 1000, url: String? = nil) -> CloudItem {
    CloudItem(id: id, parentID: "/115", name: "movie.mp4", isDirectory: false,
              pickCode: id, sha1: etag, size: size, fileExtension: "mp4", isVideo: true,
              duration: 0, thumbnailURLString: url, modifiedAt: Date(timeIntervalSince1970: date))
  }

  private func identity(_ item: CloudItem, namespace: String = "mount-a") -> ArtworkIdentity {
    ArtworkIdentity(namespace: namespace, itemID: item.id, size: item.size,
                    modifiedAt: item.modifiedAt, legacyKey: item.sha1.isEmpty ? item.id : item.sha1)
  }

  private func image() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
    }
  }

  private func service(_ probe: LoadProbe, namespace: String = "mount-a") -> ThumbnailService {
    ThumbnailService(disk: disk, namespace: { namespace }, loader: { _, _ in await probe.load() })
  }

  func testPersistentStoreIsOutsidePurgeableCaches() {
    let production = ArtworkDiskStore()
    XCTAssertTrue(production.directory.path.contains("Application Support"))
    XCTAssertFalse(production.directory.path.contains("/Caches/"))
  }

  func testColdServiceUsesOldDiskImageWithoutNetwork() async throws {
    let probe = LoadProbe(image: image())
    let first = service(probe)
    let firstImage = await first.thumbnail(for: item(), api: APIClient())
    XCTAssertNotNil(firstImage)
    // Simulate months passing and all HTTP/in-memory caches being lost.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                         ofItemAtPath: disk.fileURL(for: identity(item())).path)
    URLCache.shared.removeAllCachedResponses()
    let offline = LoadProbe(image: nil)
    let freshService = service(offline)
    let restored = await freshService.thumbnail(for: item(), api: APIClient())
    let networkCalls = await offline.calls
    XCTAssertNotNil(restored)
    XCTAssertEqual(networkCalls, 0)
    let excluded = try disk.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(excluded.isExcludedFromBackup, true)
  }

  func testRotatedETagAndSignedURLDoNotRedownload() async {
    let first = service(LoadProbe(image: image()))
    _ = await first.thumbnail(for: item(url: "https://example.invalid/a?sign=old"), api: APIClient())
    let offline = LoadProbe(image: nil)
    let restored = await service(offline).thumbnail(
      for: item(etag: "new-etag", url: "https://example.invalid/a?sign=new"), api: APIClient())
    let calls = await offline.calls
    XCTAssertNotNil(restored)
    XCTAssertEqual(calls, 0)
  }

  func testReplacedFileInvalidatesAndMountsDoNotCollide() {
    XCTAssertNotEqual(identity(item()).key, identity(item(size: 2048)).key)
    XCTAssertNotEqual(identity(item()).key, identity(item(date: 2000)).key)
    XCTAssertNotEqual(identity(item()).key, identity(item(), namespace: "mount-b").key)
    XCTAssertEqual(identity(item()).key, identity(item(etag: "rotated")).key)
  }

  func testServerOrAccountSwitchCannotReuseAnotherMountImage() async {
    _ = await service(LoadProbe(image: image())).thumbnail(for: item(), api: APIClient())
    let probe = LoadProbe(image: nil)
    let otherImage = await service(probe, namespace: "other-server-or-account")
      .thumbnail(for: item(), api: APIClient())
    let calls = await probe.calls
    XCTAssertNil(otherImage)
    XCTAssertEqual(calls, 1)
  }

  func testLegacyMigrationPreservesImageAndSurvivesCachePurge() async throws {
    try FileManager.default.createDirectory(at: disk.legacyDirectory, withIntermediateDirectories: true)
    let oldURL = disk.legacyDirectory.appendingPathComponent(ArtworkIdentity.legacyHash("etag-a") + ".jpg")
    try XCTUnwrap(image().jpegData(compressionQuality: 0.8)).write(to: oldURL)
    let offline = LoadProbe(image: nil)
    let restored = await service(offline).thumbnail(for: item(), api: APIClient())
    XCTAssertNotNil(restored)
    XCTAssertFalse(FileManager.default.fileExists(atPath: disk.legacyDirectory.path))
    let again = await service(offline).thumbnail(for: item(etag: "new"), api: APIClient())
    let calls = await offline.calls
    XCTAssertNotNil(again)
    XCTAssertEqual(calls, 0)
  }

  func testLegacyFallbackIsClaimedByOnlyOneMount() throws {
    try FileManager.default.createDirectory(at: disk.legacyDirectory, withIntermediateDirectories: true)
    let old = disk.legacyDirectory.appendingPathComponent(ArtworkIdentity.legacyHash("etag-a") + ".jpg")
    try Data([1, 2, 3]).write(to: old)
    _ = try disk.read(identity(item("/115/unrelated.mp4", etag: "other")))
    XCTAssertNil(try disk.read(identity(item(), namespace: "mount-b")))
    XCTAssertEqual(try disk.read(identity(item())), Data([1, 2, 3]))
  }

  func testCorruptCacheIsRepaired() async throws {
    try disk.write(Data("broken JPEG".utf8), for: identity(item()))
    let probe = LoadProbe(image: image())
    let result = await service(probe).thumbnail(for: item(), api: APIClient())
    let calls = await probe.calls
    XCTAssertNotNil(result)
    XCTAssertEqual(calls, 1)
    XCTAssertNotNil(UIImage(data: try XCTUnwrap(disk.read(identity(item())))))
  }

  func testCoalescesSameImageRequests() async {
    let probe = LoadProbe(image: image(), delay: 100_000_000)
    let cache = service(probe)
    let video = item()
    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<16 { group.addTask { await cache.thumbnail(for: video, api: APIClient()) != nil } }
      for await loaded in group { XCTAssertTrue(loaded) }
    }
    let calls = await probe.calls
    XCTAssertEqual(calls, 1)
  }

  func testNetworkConcurrencyIsBoundedAcrossWholePipeline() async {
    let probe = LoadProbe(image: image(), delay: 50_000_000)
    let cache = service(probe)
    let videos = (0..<12).map { item("/115/\($0).mp4") }
    await withTaskGroup(of: Bool.self) { group in
      for video in videos { group.addTask { await cache.thumbnail(for: video, api: APIClient()) != nil } }
      for await loaded in group { XCTAssertTrue(loaded) }
    }
    let peak = await probe.peakActive
    let calls = await probe.calls
    XCTAssertEqual(calls, 12)
    XCTAssertLessThanOrEqual(peak, 3)
  }

  func testCancellingOneConsumerDoesNotCancelSharedRequest() async throws {
    let probe = LoadProbe(image: image(), delay: 200_000_000)
    let cache = service(probe)
    let video = item()
    let first = Task { await cache.thumbnail(for: video, api: APIClient()) }
    await waitForCalls(probe, count: 1)
    let second = Task { await cache.thumbnail(for: video, api: APIClient()) }
    try await Task.sleep(nanoseconds: 20_000_000)
    first.cancel()
    let secondImage = await second.value
    let firstImage = await first.value
    let calls = await probe.calls
    XCTAssertNotNil(secondImage)
    XCTAssertNil(firstImage)
    XCTAssertEqual(calls, 1)
  }

  func testPlaybackCancelsNetworkThenResumesVisibleCard() async throws {
    let probe = LoadProbe(image: image(), delay: 300_000_000)
    let cache = service(probe)
    let video = item()
    let pending = Task { await cache.thumbnail(for: video, api: APIClient()) }
    await waitForCalls(probe, count: 1)
    let owner = UUID()
    await cache.suspendNetwork(for: owner)
    try await Task.sleep(nanoseconds: 100_000_000)
    let suspendedCalls = await probe.calls
    XCTAssertEqual(suspendedCalls, 1)
    await cache.resumeNetwork(for: owner)
    let loaded = await pending.value
    let resumedCalls = await probe.calls
    XCTAssertNotNil(loaded)
    XCTAssertEqual(resumedCalls, 2)
  }

  func testDiskHitsStillWorkWhilePlaybackOwnsNetwork() async {
    let probe = LoadProbe(image: image())
    _ = await service(probe).thumbnail(for: item(), api: APIClient())
    let offline = LoadProbe(image: nil)
    let cache = service(offline)
    let owner = UUID()
    await cache.suspendNetwork(for: owner)
    let loaded = await cache.thumbnail(for: item(), api: APIClient())
    XCTAssertNotNil(loaded)
    let calls = await offline.calls
    XCTAssertEqual(calls, 0)
    await cache.resumeNetwork(for: owner)
  }

  func testCancelledQueuedCardDoesNotConsumeNetworkSlot() async throws {
    let probe = LoadProbe(image: image())
    let cache = service(probe)
    let owner = UUID()
    await cache.suspendNetwork(for: owner)
    let video = item()
    let pending = Task { await cache.thumbnail(for: video, api: APIClient()) }
    try await Task.sleep(nanoseconds: 30_000_000)
    pending.cancel()
    let result = await pending.value
    XCTAssertNil(result)
    await cache.resumeNetwork(for: owner)
    let loaded = await cache.thumbnail(for: video, api: APIClient())
    let calls = await probe.calls
    XCTAssertNotNil(loaded)
    XCTAssertEqual(calls, 1)
  }

  func testClearPreventsInFlightWorkFromRepopulatingDisk() async {
    let held = HeldLoader(image: image())
    let cache = ThumbnailService(disk: disk, namespace: { "mount-a" }, loader: { _, _ in await held.load() })
    let video = item()
    let pending = Task { await cache.thumbnail(for: video, api: APIClient()) }
    for _ in 0..<200 {
      let started = await held.started
      if started { break }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let started = await held.started
    XCTAssertTrue(started)
    let cleared = await cache.clearCache()
    XCTAssertTrue(cleared)
    // Simulate a third-party loader that completes after cancellation.
    await held.finish()
    let staleImage = await pending.value
    let bytes = await cache.cacheUsageBytes()
    XCTAssertNil(staleImage)
    XCTAssertEqual(bytes, 0)
  }

  func testManualClearRemovesBothLegacyAndPersistentArtwork() throws {
    try disk.write(Data([1, 2]), for: identity(item()))
    try FileManager.default.createDirectory(at: disk.legacyDirectory, withIntermediateDirectories: true)
    try Data([3]).write(to: disk.legacyDirectory.appendingPathComponent("old.jpg"))
    XCTAssertEqual(disk.usageBytes(), 3)
    try disk.clear()
    XCTAssertEqual(disk.usageBytes(), 0)
    XCTAssertNil(try disk.read(identity(item())))
  }

  func testTransientFailureIsThrottledThenCanRecover() async throws {
    let probe = RecoveringLoader(image: image())
    let cache = ThumbnailService(disk: disk, namespace: { "mount-a" },
                                 loader: { _, _ in await probe.load() })
    let first = await cache.thumbnail(for: item(), api: APIClient())
    let immediate = await cache.thumbnail(for: item(), api: APIClient())
    XCTAssertNil(first)
    XCTAssertNil(immediate)
    let initialCalls = await probe.calls
    XCTAssertEqual(initialCalls, 1)
    try await Task.sleep(nanoseconds: 5_200_000_000)
    let recovered = await cache.thumbnail(for: item(), api: APIClient())
    XCTAssertNotNil(recovered)
    let calls = await probe.calls
    XCTAssertEqual(calls, 2)
  }

  func testDiskWriteFailureIsReported() async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let notDirectory = root.appendingPathComponent("file-not-folder")
    try Data([1]).write(to: notDirectory)
    let broken = ArtworkDiskStore(directory: notDirectory, legacyDirectory: root.appendingPathComponent("absent"))
    let cache = ThumbnailService(disk: broken, namespace: { "mount-a" })
    let saved = await cache.storeGeneratedThumbnail(image(), for: item())
    XCTAssertFalse(saved)
  }

  func testVisibleRequestsOvertakeQueuedPrefetch() async throws {
    let probe = OrderedLoader(image: image())
    let cache = ThumbnailService(disk: disk, namespace: { "mount-a" },
                                 loader: { item, _ in await probe.load(item.id) })
    let owner = UUID()
    await cache.suspendNetwork(for: owner)
    let speculative = (0..<3).map { index in
      let video = item("prefetch-\(index)")
      return Task { await cache.thumbnail(for: video, api: APIClient(), isPrefetch: true) }
    }
    await waitForQueue(cache, visible: 0, prefetch: 3)
    let visible = (0..<3).map { index in
      let video = item("visible-\(index)")
      return Task { await cache.thumbnail(for: video, api: APIClient()) }
    }
    await waitForQueue(cache, visible: 3, prefetch: 3)
    await cache.resumeNetwork(for: owner)
    for task in visible + speculative { _ = await task.value }
    let order = await probe.order
    XCTAssertEqual(order.count, 6)
    XCTAssertTrue(order.prefix(3).allSatisfy { $0.hasPrefix("visible-") })
  }

  func testSlowFrameProbesLeaveImageDownloadSlotsAvailable() async {
    let artwork = image()
    let gate = FrameGate(image: artwork)
    let cache = ThumbnailService(disk: disk, namespace: { "mount-a" },
      loader: { item, _ in item.id.hasPrefix("slow-") ? nil : artwork },
      frameLoader: { _, _ in await gate.load() })
    let slow = (0..<3).map { index in
      let video = item("slow-\(index)")
      return Task { await cache.thumbnail(for: video, api: APIClient()) }
    }
    await waitForQueue(cache, visible: 1, prefetch: 0)
    let readyFinished = expectation(description: "JPEG finishes while frame extraction is held")
    let readyVideo = item("ready-jpeg")
    let ready = Task {
      let result = await cache.thumbnail(for: readyVideo, api: APIClient())
      XCTAssertNotNil(result)
      readyFinished.fulfill()
    }
    await fulfillment(of: [readyFinished], timeout: 2)
    await gate.release()
    _ = await ready.value
    for task in slow { _ = await task.value }
    let peak = await gate.peak
    XCTAssertEqual(peak, 2)
  }

  func testPhotoArtworkUsesSharedPersistentCache() async {
    let photo = CloudItem(id: "/115/photo.jpg", parentID: "/115", name: "photo.jpg",
      isDirectory: false, pickCode: "photo", sha1: "", size: 1024,
      fileExtension: "jpg", isVideo: false, duration: 0, thumbnailURLString: nil,
      modifiedAt: Date(timeIntervalSince1970: 1000))
    let probe = LoadProbe(image: image())
    let first = await service(probe).thumbnail(for: photo, api: APIClient())
    let offline = LoadProbe(image: nil)
    let cached = await service(offline).thumbnail(for: photo, api: APIClient())
    XCTAssertNotNil(first)
    XCTAssertNotNil(cached)
    let calls = await offline.calls
    XCTAssertEqual(calls, 0)
  }

  private func waitForQueue(_ cache: ThumbnailService, visible: Int, prefetch: Int) async {
    for _ in 0..<200 {
      let counts = await cache.queuedRequestCounts()
      if counts.visible == visible, counts.prefetch == prefetch { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Queue did not reach expected state")
  }

  private func waitForCalls(_ probe: LoadProbe, count: Int) async {
    for _ in 0..<200 {
      let calls = await probe.calls
      if calls >= count { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Loader did not start")
  }
}

private actor LoadProbe {
  let image: UIImage?
  let delay: UInt64
  private(set) var calls = 0
  private(set) var peakActive = 0
  private var active = 0

  init(image: UIImage?, delay: UInt64 = 0) { self.image = image; self.delay = delay }
  func load() async -> UIImage? {
    calls += 1
    active += 1
    peakActive = max(peakActive, active)
    defer { active -= 1 }
    do { if delay > 0 { try await Task.sleep(nanoseconds: delay) } }
    catch { return nil }
    return image
  }
}

private actor HeldLoader {
  let image: UIImage
  private(set) var started = false
  private var continuation: CheckedContinuation<UIImage?, Never>?
  init(image: UIImage) { self.image = image }
  func load() async -> UIImage? {
    started = true
    return await withCheckedContinuation { continuation = $0 }
  }
  func finish() { continuation?.resume(returning: image); continuation = nil }
}

private actor RecoveringLoader {
  let image: UIImage
  private(set) var calls = 0
  init(image: UIImage) { self.image = image }
  func load() -> UIImage? {
    calls += 1
    return calls == 1 ? nil : image
  }
}

private actor OrderedLoader {
  let image: UIImage
  private(set) var order: [String] = []
  init(image: UIImage) { self.image = image }
  func load(_ id: String) async -> UIImage? {
    order.append(id)
    do { try await Task.sleep(nanoseconds: 100_000_000) }
    catch { return nil }
    return image
  }
}

private actor FrameGate {
  let image: UIImage
  private var released = false
  private var active = 0
  private(set) var peak = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  init(image: UIImage) { self.image = image }
  func load() async -> UIImage? {
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    if !released { await withCheckedContinuation { waiters.append($0) } }
    return image
  }
  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}
