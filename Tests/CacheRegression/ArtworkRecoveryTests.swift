import Foundation
import UIKit
import XCTest
@testable import CinevaCacheValidation

final class ArtworkRecoveryTests: XCTestCase {
  private var root: URL!
  private var disk: ArtworkDiskStore!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    disk = ArtworkDiskStore(directory: root)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  private func item() -> CloudItem {
    CloudItem(id: "recovery", parentID: "root", name: "movie.mp4", isDirectory: false,
      pickCode: "", sha1: "", size: 0, fileExtension: "mp4", isVideo: true,
      duration: 0, thumbnailURLString: nil, modifiedAt: Date(timeIntervalSince1970: 10))
  }
  private func image() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18)).image { context in
      UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
    }
  }
  private func source(_ id: String, original: Bool = false) -> VideoSource {
    VideoSource(id: id, title: id, definition: original ? 100 : 1,
      url: URL(string: "https://example.invalid/" + id)!,
      kind: original ? .original : .transcoded, headers: [:])
  }

  func testTemporaryFrameFailureCanRetryAfterShortBackoff() async {
    let clock = RecoveryClock(), probe = RecoveryProbe(image: image(), failFirst: true)
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      frameLoader: { _, _ in await probe.load() }, now: { clock.now })
    let first = await service.thumbnail(for: item(), api: APIClient())
    XCTAssertNil(first)
    clock.advance(6)
    let second = await service.thumbnail(for: item(), api: APIClient())
    XCTAssertNotNil(second, "Transient failure must not suppress frame generation for five minutes")
    let calls = await probe.calls
    XCTAssertEqual(calls, 2)
  }

  func testFailedPrefetchDoesNotSuppressVisibleFrame() async {
    let probe = RecoveryProbe(image: image(), failFirst: true)
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      frameLoader: { _, _ in await probe.load() })
    let first = await service.thumbnail(for: item(), api: APIClient(), isPrefetch: true)
    XCTAssertNil(first)
    let visible = await service.thumbnail(for: item(), api: APIClient())
    XCTAssertNotNil(visible, "Visible request bypasses a failed speculative frame attempt")
    let calls = await probe.calls
    XCTAssertEqual(calls, 2)
  }

  func testFailedFirstTranscodeTriesSecondWithoutResolvingOriginal() async {
    let api = APIClient(), ready = image(), probe = RecoveryCandidates()
    let low = source("low"), next = source("next")
    await api.setThumbnailSources([low, next])
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { source in
        await probe.record(source.id)
        return source.id == "next" ? ready : nil
      })
    let result = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(result)
    let attempted = await probe.ids, calls = await api.thumbnailFallbackSourceCalls
    XCTAssertEqual(attempted, ["low", "next"])
    XCTAssertEqual(calls, 0)
  }

  func testOriginalAddressIsResolvedOnlyAfterTranscodeFramesFail() async {
    let api = APIClient(), ready = image(), probe = RecoveryCandidates()
    let low = source("low"), original = source("original", original: true)
    await api.setThumbnailSources([low])
    await api.setThumbnailFallbackSource(original)
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { source in
        await probe.record(source.id)
        return source.isOriginal ? ready : nil
      })
    let result = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(result)
    let attempted = await probe.ids, fallback = await api.thumbnailFallbackAttempts
    XCTAssertEqual(attempted, ["low", "original"])
    XCTAssertEqual(fallback, [[low]])
  }

  func testSourceLookupDoesNotConsumeDecodeDeadline() async {
    let api = APIClient(), ready = image()
    await api.setThumbnailSources([source("delayed")])
    await api.setThumbnailSourceDelay(0.15)
    var timing = ThumbnailLoadTiming()
    timing.sourceSeconds = 1; timing.frameSeconds = [0.05]; timing.candidateSeconds = 0.05
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in ready }, timing: timing)
    let result = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(result, "Address lookup exceeding the decode deadline still leaves time to decode")
  }

  func testOriginalFrameRetainsFullDecodeBudget() async {
    let api = APIClient(), ready = image()
    await api.setThumbnailSources([source("original", original: true)])
    var timing = ThumbnailLoadTiming()
    timing.frameSeconds = [1]; timing.candidateSeconds = 0.05
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in
        do { try await Task.sleep(for: .seconds(0.15)) } catch { return nil }
        return ready
      }, timing: timing)
    let result = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(result, "A sole original source keeps its full bounded decode allowance")
  }

  func testTranscodeRetryCanUseLongerCandidateBudget() async {
    let api = APIClient(), ready = image(), clock = RecoveryClock()
    await api.setThumbnailSources([source("slow")])
    var timing = ThumbnailLoadTiming()
    timing.frameSeconds = [1, 2]; timing.candidateSeconds = 0.1
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in
        do { try await Task.sleep(for: .seconds(0.15)) } catch { return nil }
        return ready
      }, timing: timing, now: { clock.now })
    let first = await service.thumbnail(for: item(), api: api)
    XCTAssertNil(first)
    clock.advance(6)
    let second = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(second, "Later retries extend candidate time for a slow valid source")
  }

  func testSourceTimeoutRecoversWithoutFiveMinuteSuppression() async {
    let api = APIClient(), ready = image(), clock = RecoveryClock()
    await api.setThumbnailSources([source("delayed")])
    await api.setThumbnailSourceDelay(1)
    var timing = ThumbnailLoadTiming(); timing.sourceSeconds = 0.05
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in ready }, timing: timing, now: { clock.now })
    let first = await service.thumbnail(for: item(), api: api)
    XCTAssertNil(first)
    await api.setThumbnailSourceDelay(0)
    clock.advance(6)
    let second = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(second)
    let calls = await api.thumbnailSourcesCalls
    XCTAssertEqual(calls, 2)
  }

  func testSlowValidSourceReceivesLongerLookupBudgetOnRetry() async {
    let api = APIClient(), ready = image(), clock = RecoveryClock()
    await api.setThumbnailSources([source("slow-lookup")])
    await api.setThumbnailSourceDelay(0.15)
    var timing = ThumbnailLoadTiming(); timing.sourceSeconds = 0.1
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in ready }, timing: timing, now: { clock.now })
    let first = await service.thumbnail(for: item(), api: api)
    XCTAssertNil(first)
    clock.advance(6)
    let second = await service.thumbnail(for: item(), api: api)
    XCTAssertNotNil(second, "A slow valid lookup cannot be permanently cut off by the first-attempt deadline")
    await service.flushPersistence()
  }

  func testRateLimitRetainsBackoffEvenWhenVisible() async {
    let api = APIClient(), clock = RecoveryClock()
    await api.setThumbnailSourceError(CloudProviderError.rateLimited("fixture"))
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in nil }, now: { clock.now })
    let first = await service.thumbnail(for: item(), api: api, isPrefetch: true)
    XCTAssertNil(first)
    clock.advance(6)
    let second = await service.thumbnail(for: item(), api: api)
    XCTAssertNil(second)
    let calls = await api.thumbnailSourcesCalls
    XCTAssertEqual(calls, 1, "Foreground promotion cannot bypass server rate limits")
  }

  func testPlaybackInterruptionResumesSourceLookupWithoutFailureBackoff() async {
    let api = APIClient(), ready = image(), owner = UUID()
    await api.setThumbnailSources([source("interrupted")])
    await api.setThumbnailSourceDelay(5)
    let service = ThumbnailService(disk: disk, namespace: { "recovery" }, loader: { _, _ in nil },
      sourceFrameLoader: { _ in ready })
    let video = item()
    let pending = Task { await service.thumbnail(for: video, api: api) }
    for _ in 0..<200 {
      let calls = await api.thumbnailSourcesCalls
      if calls > 0 { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let started = await api.thumbnailSourcesCalls
    XCTAssertEqual(started, 1)
    await service.suspendNetwork(for: owner)
    await api.setThumbnailSourceDelay(0)
    await service.resumeNetwork(for: owner)
    let result = await pending.value, calls = await api.thumbnailSourcesCalls
    XCTAssertNotNil(result, "Returning from playback must retry the cancelled address lookup immediately")
    XCTAssertEqual(calls, 2)
    await service.flushPersistence()
  }
}

private final class RecoveryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 100)
  var now: Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private actor RecoveryProbe {
  let image: UIImage
  let failFirst: Bool
  private(set) var calls = 0
  init(image: UIImage, failFirst: Bool) { self.image = image; self.failFirst = failFirst }
  func load() -> UIImage? { calls += 1; return failFirst && calls == 1 ? nil : image }
}
private actor RecoveryCandidates {
  private(set) var ids: [String] = []
  func record(_ id: String) { ids.append(id) }
}
