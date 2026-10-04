import Foundation

private actor LookupEvents {
  enum Event: Equatable { case originalStarted, initialReady, remainingReady }
  private var pending: [Event] = []
  private var waiter: CheckedContinuation<Event, Never>?
  func record(_ event: Event) {
    if let waiter { self.waiter = nil; waiter.resume(returning: event) }
    else { pending.append(event) }
  }
  func next() async -> Event {
    if !pending.isEmpty { return pending.removeFirst() }
    return await withCheckedContinuation { waiter = $0 }
  }
}

private actor LookupFixture {
  let events = LookupEvents()
  private let originalValue: VideoSource
  private let transcodedValues: [VideoSource]
  private let originalError: Error?
  private let transcodeError: Error?
  private var blockOriginal: Bool
  private var completion: CheckedContinuation<Void, Never>?
  private var originalCalls = 0
  private var transcodeCalls = 0
  init(original: VideoSource, transcodes: [VideoSource], blockOriginal: Bool = false,
       originalError: Error? = nil, transcodeError: Error? = nil) {
    originalValue = original; transcodedValues = transcodes
    self.blockOriginal = blockOriginal; self.originalError = originalError; self.transcodeError = transcodeError
  }
  func original() async throws -> VideoSource {
    originalCalls += 1
    if blockOriginal {
      await withCheckedContinuation { continuation in
        completion = continuation
        Task { await events.record(.originalStarted) }
      }
    } else { await events.record(.originalStarted) }
    if let originalError { throw originalError }
    return originalValue
  }
  func transcodes() throws -> [VideoSource] {
    transcodeCalls += 1
    if let transcodeError { throw transcodeError }
    return transcodedValues
  }
  func releaseOriginal() { blockOriginal = false; completion?.resume(); completion = nil }
  var counts: (original: Int, transcodes: Int) { (originalCalls, transcodeCalls) }
  var originalIsBlocked: Bool { completion != nil }
}

@main struct SourceSelectionChecks {
  static func main() async throws {
    var checks = 0
    func expect(_ ok: Bool, _ name: String) { precondition(ok, name); checks += 1 }
    func source(_ id: String, _ definition: Int, _ kind: VideoSource.Kind) -> VideoSource {
      VideoSource(id: id, title: id, definition: definition,
        url: URL(string: "https://example.invalid/" + id)!, kind: kind, headers: [:])
    }
    func initial(_ fixture: LookupFixture, preferOriginal: Bool) async throws -> (sources: [VideoSource], hasDeferredSources: Bool) {
      try await Cloud115PlaybackSourceSelection.initial(preferOriginal: preferOriginal,
        original: { try await fixture.original() }, transcodes: { try await fixture.transcodes() })
    }
    func remaining(_ fixture: LookupFixture, preferOriginal: Bool) async throws -> [VideoSource] {
      try await Cloud115PlaybackSourceSelection.remaining(preferOriginal: preferOriginal,
        original: { try await fixture.original() }, transcodes: { try await fixture.transcodes() })
    }
    func kind(_ error: Error) -> String {
      if error is CancellationError { return "cancelled" }
      if let error = error as? CloudProviderError {
        switch error {
        case .authenticationRequired: return "authentication"
        case .rateLimited: return "rate-limit"
        case .network: return "network"
        default: return "provider"
        }
      }
      return "other"
    }
    let original = source("original", 100, .original)
    let low = source("low", 1, .transcoded), high = source("high", 4, .transcoded)

    // The downurl completion is controlled by this fixture, not a sleep or a
    // wall-clock threshold. Initial playback must finish before it is released.
    let slow = LookupFixture(original: original, transcodes: [low, high, low], blockOriginal: true)
    let first = Task {
      let result = try await initial(slow, preferOriginal: false)
      await slow.events.record(.initialReady)
      return result
    }
    expect(await slow.events.next() == .initialReady,
      "Playable transcode is returned before any slow original lookup starts")
    let firstResult = try await first.value
    let firstCounts = await slow.counts
    expect(firstCounts.original == 0 && firstCounts.transcodes == 1,
      "Transcoded startup makes exactly one requested-quality lookup")
    expect(firstResult.sources == [high, low] && firstResult.hasDeferredSources,
      "Highest transcode wins, duplicate qualities are removed and original is deferred")
    let deferred = Task {
      let result = try await remaining(slow, preferOriginal: false)
      await slow.events.record(.remainingReady)
      return result
    }
    expect(await slow.events.next() == .originalStarted, "Deferred quality menu starts the original lookup")
    expect(await slow.originalIsBlocked, "Slow downurl remains blocked until the fixture completes it")
    await slow.releaseOriginal()
    expect(await slow.events.next() == .remainingReady, "Original completes only after explicit release")
    expect(try await deferred.value == [original], "Original quality remains available after startup")
    let deferredCounts = await slow.counts
    expect(deferredCounts.original == 1 && deferredCounts.transcodes == 1,
      "Delayed menu does not repeat the already playable transcode lookup")

    let failedOriginal = LookupFixture(original: original, transcodes: [high],
      originalError: CloudProviderError.missingOriginalURL)
    let fallback = try await initial(failedOriginal, preferOriginal: true)
    let fallbackCounts = await failedOriginal.counts
    expect(fallback.sources == [high] && !fallback.hasDeferredSources,
      "Failed original immediately falls back to the available transcode")
    expect(fallbackCounts.original == 1 && fallbackCounts.transcodes == 1,
      "A failed downurl is not requested again during the same launch")

    let success = LookupFixture(original: original, transcodes: [low, high])
    let originalStart = try await initial(success, preferOriginal: true)
    let originalCounts = await success.counts
    expect(originalStart.sources == [original] && originalStart.hasDeferredSources,
      "Original preference still starts the original and defers transcodes")
    expect(originalCounts.original == 1 && originalCounts.transcodes == 0,
      "Original startup never waits for a transcode request")
    expect(try await remaining(success, preferOriginal: true) == [high, low],
      "Deferred transcode quality menu remains sorted")

    for transcodeError in [nil, CloudProviderError.network("fixture unavailable")] {
      let empty = LookupFixture(original: original, transcodes: [], transcodeError: transcodeError)
      let result = try await initial(empty, preferOriginal: false)
      let counts = await empty.counts
      expect(result.sources == [original] && !result.hasDeferredSources,
        "Empty or failed transcodes preserve original fallback")
      expect(counts.original == 1 && counts.transcodes == 1, "Fallback makes one lookup of each kind")
    }
    let bothFailed = LookupFixture(original: original, transcodes: [],
      originalError: CloudProviderError.missingOriginalURL, transcodeError: CloudProviderError.network("fixture unavailable"))
    do {
      _ = try await initial(bothFailed, preferOriginal: false)
      expect(false, "Both failed sources must throw")
    } catch { expect(kind(error) == "network", "Original fallback cannot erase the requested transcode failure") }

    let blockingErrors: [(Error, String)] = [
      (CloudProviderError.authenticationRequired("fixture auth"), "authentication"),
      (CloudProviderError.rateLimited("fixture rate"), "rate-limit"),
      (CancellationError(), "cancelled"),
      (URLError(.cancelled), "cancelled"),
    ]
    for preferOriginal in [false, true] {
      for (error, expectedKind) in blockingErrors {
        let fixture = LookupFixture(original: original, transcodes: [high],
          originalError: preferOriginal ? error : nil, transcodeError: preferOriginal ? nil : error)
        do {
          _ = try await initial(fixture, preferOriginal: preferOriginal)
          expect(false, "Cancellation, auth and rate limits must propagate")
        } catch { expect(kind(error) == expectedKind, "Critical failures keep their original category") }
        let counts = await fixture.counts
        expect(preferOriginal ? counts.original == 1 && counts.transcodes == 0 : counts.original == 0 && counts.transcodes == 1,
          "A critical failure cannot start the alternate lookup")
      }
    }
    // An auth/rate-limit error from the fallback also remains visible.
    for error in [CloudProviderError.authenticationRequired("fixture auth"), .rateLimited("fixture rate")] {
      let fixture = LookupFixture(original: original, transcodes: [], originalError: error)
      do { _ = try await initial(fixture, preferOriginal: false); expect(false, "Fallback critical failure must throw") }
      catch { expect(kind(error) == "authentication" || kind(error) == "rate-limit", "Fallback cannot hide authentication or rate limits") }
    }

    let cancelled = LookupFixture(original: original, transcodes: [high], blockOriginal: true)
    let cancelledTask = Task { try await initial(cancelled, preferOriginal: true) }
    expect(await cancelled.events.next() == .originalStarted, "Cancellation fixture reaches controlled downurl")
    cancelledTask.cancel(); await cancelled.releaseOriginal()
    do { _ = try await cancelledTask.value; expect(false, "Cancelled lookup cannot publish a source") }
    catch { expect(kind(error) == "cancelled", "Cancellation after lookup completion propagates") }
    let cancelledCounts = await cancelled.counts
    expect(cancelledCounts.original == 1 && cancelledCounts.transcodes == 0,
      "Cancelled startup never launches fallback work")
    print("115 source selection checks passed: \(checks); controlled lookups only, NOT live 115 network timing")
  }
}
