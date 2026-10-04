import Foundation

private actor ThumbnailLookupEvents {
  enum Event: Equatable { case originalStarted, transcodesStarted, initialReady }
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

private actor ThumbnailLookupFixture {
  let events = ThumbnailLookupEvents()
  private let originalValue: VideoSource
  private let transcodedValues: [VideoSource]
  private let originalError: Error?
  private let transcodeError: Error?
  private var blockOriginal: Bool
  private var blockTranscodes: Bool
  private var originalCompletion: CheckedContinuation<Void, Never>?
  private var transcodeCompletion: CheckedContinuation<Void, Never>?
  private var originalCalls = 0
  private var transcodeCalls = 0

  init(original: VideoSource, transcodes: [VideoSource], blockOriginal: Bool = false,
       blockTranscodes: Bool = false, originalError: Error? = nil, transcodeError: Error? = nil) {
    originalValue = original; transcodedValues = transcodes
    self.blockOriginal = blockOriginal; self.blockTranscodes = blockTranscodes
    self.originalError = originalError; self.transcodeError = transcodeError
  }

  func original() async throws -> VideoSource {
    originalCalls += 1
    if blockOriginal {
      await withCheckedContinuation { continuation in
        originalCompletion = continuation
        Task { await events.record(.originalStarted) }
      }
    } else { await events.record(.originalStarted) }
    if let originalError { throw originalError }
    return originalValue
  }

  func transcodes() async throws -> [VideoSource] {
    transcodeCalls += 1
    if blockTranscodes {
      await withCheckedContinuation { continuation in
        transcodeCompletion = continuation
        Task { await events.record(.transcodesStarted) }
      }
    } else { await events.record(.transcodesStarted) }
    if let transcodeError { throw transcodeError }
    return transcodedValues
  }

  func releaseOriginal() {
    blockOriginal = false; originalCompletion?.resume(); originalCompletion = nil
  }

  func releaseTranscodes() {
    blockTranscodes = false; transcodeCompletion?.resume(); transcodeCompletion = nil
  }

  var counts: (original: Int, transcodes: Int) { (originalCalls, transcodeCalls) }
}

// A task cannot enter source selection until the test explicitly opens this
// gate. This makes cancellation-before-lookup deterministic without sleeps.
private actor ThumbnailInvocationGate {
  private var entered = false
  private var completion: CheckedContinuation<Void, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      completion = continuation; entered = true
      startWaiter?.resume(); startWaiter = nil
    }
  }

  func awaitStart() async {
    if entered { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func release() { completion?.resume(); completion = nil }
}

private enum ThumbnailFixtureError: Error { case originalUnavailable }

@main struct ThumbnailSourceChecks {
  static func main() async throws {
    var checks = 0
    func expect(_ ok: Bool, _ name: String) { precondition(ok, name); checks += 1 }
    func source(_ id: String, _ definition: Int, _ kind: VideoSource.Kind = .transcoded,
                url: URL? = nil, headers: [String: String] = [:]) -> VideoSource {
      VideoSource(id: id, title: id, definition: definition,
        url: url ?? URL(string: "https://example.invalid/" + id)!, kind: kind, headers: headers)
    }
    func initial(_ fixture: ThumbnailLookupFixture) async throws -> [VideoSource] {
      try await Cloud115ThumbnailSourceSelection.initial(
        original: { try await fixture.original() }, transcodes: { try await fixture.transcodes() })
    }
    func fallback(_ fixture: ThumbnailLookupFixture, attempted: [VideoSource]) async throws -> VideoSource? {
      try await Cloud115ThumbnailSourceSelection.fallback(attempted: attempted,
        original: { try await fixture.original() })
    }
    func errorSignature(_ error: Error) -> String {
      if error is CancellationError { return "cancelled" }
      if let error = error as? URLError, error.code == .cancelled { return "cancelled" }
      if let error = error as? URLError { return "URLError:\(error.code.rawValue)" }
      if let error = error as? CloudProviderError {
        switch error {
        case .authenticationRequired(let message): return "authentication:\(message)"
        case .rateLimited(let message): return "rate-limit:\(message)"
        case .network(let message): return "network:\(message)"
        case .missingOriginalURL: return "missing-original"
        default: return "provider:\(String(describing: error))"
        }
      }
      return String(reflecting: error)
    }
    func expectError(_ expected: Error, _ name: String, operation: () async throws -> Void) async {
      do { try await operation(); expect(false, "\(name) must throw") }
      catch { expect(errorSignature(error) == errorSignature(expected), "\(name) preserves its error") }
    }

    let original = source("original", 100, .original)
    let low = source("low", 1, headers: ["Authorization": "fixture-a", "User-Agent": "Fixture"])
    let middle = source("middle", 2), high = source("high", 4)
    let lowDuplicate = source("different-id", 1, url: low.url,
      headers: ["User-Agent": "Fixture", "Authorization": "fixture-a"])

    // The original lookup is deliberately blocked: usable low-quality
    // transcodes must be published without starting or waiting for downurl.
    let slowOriginal = ThumbnailLookupFixture(original: original,
      transcodes: [high, lowDuplicate, middle, low], blockOriginal: true)
    let firstTask = Task {
      let result = try await initial(slowOriginal)
      await slowOriginal.events.record(.initialReady)
      return result
    }
    expect(await slowOriginal.events.next() == .transcodesStarted, "Thumbnail starts with transcodes")
    expect(await slowOriginal.events.next() == .initialReady, "Thumbnail is ready before any original lookup")
    let first = try await firstTask.value
    let firstCounts = await slowOriginal.counts
    expect(first.map(\.definition) == [1, 2], "Thumbnail sources are ascending and limited to two")
    expect(first.first?.url == low.url && first.first?.headers == low.headers,
      "Duplicate URL and headers keep the same request identity despite a different source id")
    expect(firstCounts.original == 0 && firstCounts.transcodes == 1,
      "Usable transcodes require one lookup and leave original lazy")

    let duplicatesOnly = ThumbnailLookupFixture(original: original, transcodes: [low, lowDuplicate])
    let deduplicated = try await initial(duplicatesOnly)
    expect(deduplicated.count == 1 && deduplicated.first?.url == low.url,
      "Same URL and equal headers deduplicate even when dictionary insertion order differs")
    let duplicateCounts = await duplicatesOnly.counts
    expect(duplicateCounts.original == 0 && duplicateCounts.transcodes == 1,
      "A single unique transcode does not fetch original to fill the two-source limit")

    let otherCredentials = source("same-url-other-credentials", 2, url: low.url,
      headers: ["Authorization": "fixture-b", "User-Agent": "Fixture"])
    let distinctHeaders = ThumbnailLookupFixture(original: original, transcodes: [otherCredentials, low])
    expect(try await initial(distinctHeaders) == [low, otherCredentials],
      "The same URL with different headers preserves both request identities")

    let repeatedID = source(low.id, 2, url: middle.url, headers: low.headers)
    let distinctURLs = ThumbnailLookupFixture(original: original, transcodes: [repeatedID, low])
    expect(try await initial(distinctURLs) == [low, repeatedID],
      "A repeated source id cannot remove a different URL")

    let recoverableErrors: [Error?] = [nil, CloudProviderError.network("fixture network"), URLError(.timedOut)]
    for transcodeError in recoverableErrors {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: [], transcodeError: transcodeError)
      expect(try await initial(fixture) == [original], "Empty or ordinary network failure falls back to original")
      let counts = await fixture.counts
      expect(counts.original == 1 && counts.transcodes == 1, "Initial fallback makes exactly one lookup of each kind")
    }

    let criticalErrors: [Error] = [
      CloudProviderError.authenticationRequired("fixture auth"),
      CloudProviderError.rateLimited("fixture rate"),
      CancellationError(),
      URLError(.cancelled),
    ]
    for error in criticalErrors {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: [low], transcodeError: error)
      await expectError(error, "Critical transcode failure") { _ = try await initial(fixture) }
      let counts = await fixture.counts
      expect(counts.original == 0 && counts.transcodes == 1, "Critical transcode failure cannot start original")
    }

    let originalErrors: [Error] = criticalErrors + [
      CloudProviderError.network("fixture original network"),
      CloudProviderError.missingOriginalURL,
      ThumbnailFixtureError.originalUnavailable,
    ]
    for error in originalErrors {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: [], originalError: error)
      await expectError(error, "Initial original failure") { _ = try await initial(fixture) }
      let counts = await fixture.counts
      expect(counts.original == 1 && counts.transcodes == 1, "Initial original failure is not retried")
    }

    for attempted in [[original], [low, original, middle]] {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: [])
      expect(try await fallback(fixture, attempted: attempted) == nil,
        "An already attempted original suppresses redundant fallback")
      let counts = await fixture.counts
      expect(counts.original == 0 && counts.transcodes == 0, "Already attempted original performs no lookup")
    }
    for attempted in [[VideoSource](), [low, middle]] {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: [])
      expect(try await fallback(fixture, attempted: attempted) == original,
        "Empty or transcode-only attempts lazily acquire original")
      let counts = await fixture.counts
      expect(counts.original == 1 && counts.transcodes == 0, "Fallback only requests original once")
    }
    for error in originalErrors {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: [], originalError: error)
      await expectError(error, "Lazy original failure") { _ = try await fallback(fixture, attempted: [low]) }
      let counts = await fixture.counts
      expect(counts.original == 1 && counts.transcodes == 0, "Lazy original failure is propagated without another lookup")
    }

    let initialGate = ThumbnailInvocationGate()
    let cancelledInitial = ThumbnailLookupFixture(original: original, transcodes: [low])
    let initialTask = Task {
      await initialGate.wait()
      return try await initial(cancelledInitial)
    }
    await initialGate.awaitStart(); initialTask.cancel(); await initialGate.release()
    await expectError(CancellationError(), "Cancellation before initial selection") { _ = try await initialTask.value }
    let initialCounts = await cancelledInitial.counts
    expect(initialCounts.original == 0 && initialCounts.transcodes == 0,
      "Already cancelled initial selection cannot start either lookup")

    let cancelledTranscodeResults: [(sources: [VideoSource], error: Error?)] = [
      ([low], nil), ([], nil), ([], CloudProviderError.network("fixture cancelled network")),
    ]
    for result in cancelledTranscodeResults {
      let fixture = ThumbnailLookupFixture(original: original, transcodes: result.sources,
        blockTranscodes: true, transcodeError: result.error)
      let task = Task { try await initial(fixture) }
      expect(await fixture.events.next() == .transcodesStarted,
        "Initial cancellation reaches the controlled transcode lookup")
      task.cancel(); await fixture.releaseTranscodes()
      await expectError(CancellationError(), "Cancellation after transcode completion") { _ = try await task.value }
      let counts = await fixture.counts
      expect(counts.original == 0 && counts.transcodes == 1,
        "Cancelled transcode result or failure cannot publish a source or start original fallback")
    }

    let cancelledInitialOriginal = ThumbnailLookupFixture(original: original, transcodes: [], blockOriginal: true)
    let initialOriginalTask = Task { try await initial(cancelledInitialOriginal) }
    expect(await cancelledInitialOriginal.events.next() == .transcodesStarted,
      "Initial fallback first completes the transcode lookup")
    expect(await cancelledInitialOriginal.events.next() == .originalStarted,
      "Initial fallback cancellation reaches the controlled original lookup")
    initialOriginalTask.cancel(); await cancelledInitialOriginal.releaseOriginal()
    await expectError(CancellationError(), "Cancellation after initial original completion") { _ = try await initialOriginalTask.value }
    let initialOriginalCounts = await cancelledInitialOriginal.counts
    expect(initialOriginalCounts.original == 1 && initialOriginalCounts.transcodes == 1,
      "Cancelled initial original cannot be published or retried")

    let beforeGate = ThumbnailInvocationGate()
    let cancelledBefore = ThumbnailLookupFixture(original: original, transcodes: [])
    let beforeTask = Task {
      await beforeGate.wait()
      return try await fallback(cancelledBefore, attempted: [low])
    }
    await beforeGate.awaitStart(); beforeTask.cancel(); await beforeGate.release()
    await expectError(CancellationError(), "Cancellation before lazy fallback") { _ = try await beforeTask.value }
    let beforeCounts = await cancelledBefore.counts
    expect(beforeCounts.original == 0 && beforeCounts.transcodes == 0,
      "Already cancelled fallback cannot start original")

    let cancelledAfter = ThumbnailLookupFixture(original: original, transcodes: [], blockOriginal: true)
    let afterTask = Task { try await fallback(cancelledAfter, attempted: [low]) }
    expect(await cancelledAfter.events.next() == .originalStarted, "Fallback cancellation reaches a controlled original lookup")
    afterTask.cancel(); await cancelledAfter.releaseOriginal()
    await expectError(CancellationError(), "Cancellation after lazy original completion") { _ = try await afterTask.value }
    let afterCounts = await cancelledAfter.counts
    expect(afterCounts.original == 1 && afterCounts.transcodes == 0,
      "Cancelled fallback cannot publish the completed original or repeat its lookup")

    print("115 thumbnail source selection checks passed: \(checks); controlled lookups only, NOT live 115 network timing")
  }
}
