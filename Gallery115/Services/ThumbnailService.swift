import AVFoundation
import Foundation
import ImageIO
import OSLog
import UIKit

struct ThumbnailLibraryPage: Sendable {
  let items: [CloudItem]
  let nextOffset: Int?
}

struct ThumbnailLoadTiming: Sendable {
  var artworkSeconds = 18.0
  var sourceSeconds = 20.0
  var frameSeconds = [15.0, 30.0, 60.0]
  var candidateSeconds = 8.0
}

/// Local-first artwork; a small bounded pool fills visible rows while playback has priority.
actor ThumbnailService {
  typealias Loader = @Sendable (CloudItem, APIClient) async -> UIImage?
  typealias SourceFrameLoader = @Sendable (VideoSource) async -> UIImage?
  private struct Work {
    let id: UUID
    let task: Task<UIImage?, Never>
    var clients: [UUID: Bool] // true only while this consumer is speculative.
    var isPrefetch: Bool
    let pixels: Int
  }
  private struct SlotWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
    var isPrefetch: Bool
    let isFrame: Bool
  }

  private let imageWorker: ArtworkImageWorker
  private struct PendingWrite {
    let identity: ArtworkIdentity
    let image: UIImage
    let data: Data?
    let generation: UUID
    var cost: Int { data?.count ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4) }
  }
  private var pendingWrites: [String: PendingWrite] = [:]
  private var writeOrder: [String] = []
  private var persistenceTask: Task<Void, Never>?
  private var persistenceID: UUID?
  private var gridOwners = Set<UUID>()
  private var activePrefetchSlots = Set<UUID>()
  private var activePrefetchFrameSlots = Set<UUID>()
  private var badURLs: [URL: Date] = [:]
  private let disk: ArtworkDiskStore
  private let namespace: @Sendable () -> String
  private let loader: Loader?
  private let frameLoader: Loader?
  private let sourceFrameLoader: SourceFrameLoader?
  private let timing: ThumbnailLoadTiming
  private let now: @Sendable () -> Date
  private nonisolated let memoryCache = ArtworkMemoryCache()
  private let logger = Logger(subsystem: "com.xiaocai.gallery115", category: "Artwork")
  private var inFlight: [String: Work] = [:]
  private var frameAttempts: [String: Int] = [:]
  private struct FrameFailure {
    let until: Date
    let wasPrefetch: Bool
    let blocked: Bool
  }
  private var frameFailedUntil: [String: FrameFailure] = [:]
  private var failedUntil: [String: Date] = [:]
  private var activeSlots: Set<UUID> = []
  private var activeFrameSlots: Set<UUID> = []
  private var slotWaiters: [SlotWaiter] = []
  private var playbackOwners: Set<UUID> = []
  private var endedPlaybackOwners: Set<UUID> = []
  private var cacheGeneration: UUID
  private var directoryWork: (id: UUID, task: Task<ThumbnailLibraryPage?, Never>)?
  private var backgroundFailedUntil: [String: Date] = [:]
  private(set) var libraryReloadRevision = 0
  private var completedLibraryReloadRevision = 0
  private var libraryIdleWait: (id: UUID, task: Task<Void, Never>)?
  private var libraryScanID = UUID()
  private let maximumNetworkJobs = 3
  private let maximumFrameJobs = 2
  private let imageSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    configuration.httpMaximumConnectionsPerHost = 3
    return URLSession(configuration: configuration)
  }()

  init(
    disk: ArtworkDiskStore = ArtworkDiskStore(),
    namespace: @escaping @Sendable () -> String = { ThumbnailService.currentNamespace() },
    loader: Loader? = nil,
    frameLoader: Loader? = nil,
    sourceFrameLoader: SourceFrameLoader? = nil,
    timing: ThumbnailLoadTiming = ThumbnailLoadTiming(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let generation = UUID()
    self.cacheGeneration = generation
    self.imageWorker = ArtworkImageWorker(disk: disk, generation: generation)
    self.disk = disk
    self.namespace = namespace
    self.loader = loader
    self.frameLoader = frameLoader
    self.sourceFrameLoader = sourceFrameLoader
    self.timing = timing
    self.now = now
    memoryCache.countLimit = 160
    memoryCache.totalCostLimit = 72 * 1_024 * 1_024
  }

  nonisolated static func currentNamespace() -> String {
    if MediaSourceSelectionStore.shared.resolvedSource == .cloud115 {
      // One 115 account can be active at a time and its credentials never enter
      // the cache key. Disconnecting an account clears the in-memory generation.
      return "115-open-api-v1"
    }
    guard let config = WebDAVCredentialStore.shared.configuration else { return "unconfigured" }
    // Full endpoint includes scheme, port and base path. Never include passwords.
    return [config.normalizedWebDAVURL?.absoluteString ?? config.serverURL,
            config.username, config.normalizedRootPath].map { "\($0.utf8.count):\($0)" }.joined()
  }

  private func identity(for item: CloudItem) -> ArtworkIdentity {
    let scope = namespace()
    memoryCache.namespaceSnapshot = scope
    return ArtworkIdentity(namespace: scope, itemID: item.id, size: item.size,
                    modifiedAt: item.modifiedAt, legacyKey: item.sha1.isEmpty ? item.id : item.sha1)
  }

  /// NSCache lookups are thread-safe and never touch disk or decode on the UI thread.
  nonisolated func cachedThumbnail(for item: CloudItem) -> UIImage? {
    guard let scope = memoryCache.namespaceSnapshot else { return nil }
    let identity = ArtworkIdentity(namespace: scope, itemID: item.id, size: item.size,
      modifiedAt: item.modifiedAt, legacyKey: item.sha1.isEmpty ? item.id : item.sha1)
    return memoryCache.object(forKey: identity.key as NSString)
  }

  nonisolated func traceKey(for item: CloudItem) -> String {
    ArtworkIdentity(namespace: memoryCache.namespaceSnapshot ?? namespace(), itemID: item.id,
      size: item.size, modifiedAt: item.modifiedAt, legacyKey: item.sha1.isEmpty ? item.id : item.sha1).key
  }

  func warmLocalThumbnails(_ items: [CloudItem], limit: Int = 24) async {
    let generation = cacheGeneration
    for item in items.lazy.filter({ $0.isVideo || $0.isPhoto }).prefix(max(0, limit)) {
      guard !Task.isCancelled, generation == cacheGeneration, playbackOwners.isEmpty else { return }
      _ = await localImage(identity(for: item), maximumPixelSize: 320, generation: generation)
      await Task.yield()
    }
  }

  func thumbnail(for item: CloudItem, api: APIClient, isPrefetch: Bool = false, targetPixels: Int = 640) async -> UIImage? {
    guard item.isVideo || item.isPhoto else { return nil }
    let requestedAt = ProcessInfo.processInfo.systemUptime
    let pixels = ArtworkSizeTier.pixels(for: targetPixels)
    let identity = identity(for: item)
    let generation = cacheGeneration
    while !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() {
      if let image = memoryCache.suitable(forKey: identity.key as NSString, pixels: pixels) {
        GridArtworkTrace.event("memory-hit", id: identity.key, since: requestedAt)
        return image
      }
      if let retry = failedUntil[identity.key], retry > now() { return nil }

      let clientID = UUID()
      let work: Work
      if var existing = inFlight[identity.key] {
        GridArtworkTrace.event("deduplicated", id: identity.key)
        let previousPriority=existing.isPrefetch
        existing.clients[clientID]=isPrefetch
        existing.isPrefetch=existing.clients.values.allSatisfy { $0 }
        inFlight[identity.key] = existing
        if previousPriority != existing.isPrefetch { updatePriority(existing) }
        work = existing
      } else {
        let workID = UUID()
        let task = Task<UIImage?, Never> { [weak self] in
          guard let self else { return nil }
          return await self.load(item, identity: identity, api: api, generation: generation, workID: workID, isPrefetch: isPrefetch, pixels: pixels)
        }
        work = Work(id: workID, task: task, clients: [clientID:isPrefetch], isPrefetch: isPrefetch, pixels: pixels)
        inFlight[identity.key] = work
      }

      let completion = ArtworkCompletion<UIImage>()
      let result = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          completion.install(continuation)
          let observer = Task { completion.finish(await work.task.value) }
          completion.attach([observer])
        }
      } onCancel: {
        // Stop THIS waiter immediately, even when another card still needs the
        // shared request. Old scans must not keep waiting behind visible cells.
        completion.finish(nil)
        Task { await self.cancelClient(clientID, key: identity.key, workID: work.id) }
      }
      guard !Task.isCancelled else {
        // A cancelled consumer must acknowledge ownership removal on this actor
        // before returning. Otherwise resumeNetwork can start its abandoned job
        // before the cancellation handler's unstructured cleanup task runs.
        cancelClient(clientID, key: identity.key, workID: work.id)
        return nil
      }
      if inFlight[identity.key]?.id == work.id {
        inFlight[identity.key] = nil
        if result == nil, !isPrefetch, !work.task.isCancelled, generation == cacheGeneration {
          failedUntil[identity.key] = now().addingTimeInterval(5)
        }
      }
      guard !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() else { return nil }
      // Playback cancellation isn't a failure. Interested cards retry behind
      // the closed gate and resume when the player closes.
      if work.task.isCancelled { continue }
      if result != nil, work.pixels < pixels { continue }
      GridArtworkTrace.event("delivery", id: identity.key, detail: "pixels=\(pixels) prefetch=\(isPrefetch)", since: requestedAt)
      return result
    }
    return nil
  }

  func generatedThumbnail(for item: CloudItem, api: APIClient) async -> UIImage? {
    await thumbnail(for: item, api: api)
  }

  func prefetch(_ items: [CloudItem], api: APIClient, limit: Int = 12) async {
    // Only one speculative load at a time. Visible cards still fill the other
    // slots and jump ahead of queued prefetches after a fast scroll.
    let targets = Array(items.lazy.filter { $0.isVideo || $0.isPhoto }.prefix(max(limit, 0)))
    for item in targets {
      guard !Task.isCancelled else { return }
      _ = await thumbnail(for: item, api: api, isPrefetch: true)
    }
  }

  /// One app-owned walk, independent of scrolling. Keep at most three missing
  /// covers in flight; existing network/frame gates still give playback priority.
  func fillLibrary(rootID: String, api: APIClient) async {
    let scanID = UUID()
    libraryScanID = scanID
    directoryWork?.task.cancel()
    let generation = cacheGeneration
    let reloadRevision = libraryReloadRevision
    let refreshDirectory = reloadRevision != completedLibraryReloadRevision
    var folders = [rootID]
    var visited = Set([rootID])
    var cursor = 0
    await withTaskGroup(of: Void.self) { group in
      var pending = 0
      while cursor < folders.count, !Task.isCancelled,
        generation == cacheGeneration, libraryScanID == scanID {
        let folder = folders[cursor]
        cursor += 1
        var offset = 0
        while !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID {
          let workID = UUID()
          guard await acquireSlot(workID, isPrefetch: true) else { group.cancelAll(); return }
          guard !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID else {
            releaseSlot(workID); group.cancelAll(); return
          }
          let requestedOffset = offset
          let task = Task {
            await Self.boundedLibraryPage(seconds: 30) {
              try? await api.thumbnailLibraryPage(id: folder, offset: requestedOffset, forceRefresh: refreshDirectory)
            }
          }
          directoryWork = (workID, task)
          let page = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
          if directoryWork?.id == workID { directoryWork = nil }
          releaseSlot(workID)
          guard !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID else {
            group.cancelAll(); return
          }
          if task.isCancelled { continue } // Playback preempted this page.
          guard let page else { break } // A bad folder cannot hold all later folders.
          for item in page.items {
            await Task.yield()
            guard !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID else {
              group.cancelAll(); return
            }
            if item.isDirectory {
              if visited.insert(item.id).inserted { folders.append(item.id) }
              continue
            }
            guard item.isVideo || item.isPhoto else { continue }
            if pending >= 3 {
              await group.next()
              pending -= 1
            }
            guard !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID else {
              group.cancelAll(); return
            }
            group.addTask { [self] in
              await fillMissingThumbnail(item, api: api, generation: generation, scanID: scanID)
            }
            pending += 1
          }
          guard let next = page.nextOffset, next > offset else { break }
          offset = next
        }
      }
      if Task.isCancelled || generation != cacheGeneration || libraryScanID != scanID { group.cancelAll() }
    }
    if !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID {
      completedLibraryReloadRevision = reloadRevision
    }
    backgroundFailedUntil = backgroundFailedUntil.filter { $0.value > Date() }
  }

  private func fillMissingThumbnail(_ item: CloudItem, api: APIClient, generation: UUID, scanID: UUID) async {
    guard !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID else { return }
    let identity = identity(for: item)
    if cachedThumbnail(for: item) != nil { return }
    // Inspect disk metadata without decoding every cached cover into memory.
    if await imageWorker.contains(identity, generation: generation) { return }
    guard !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID else { return }
    if let until = backgroundFailedUntil[identity.key], until > Date() { return }
    let revision = libraryReloadRevision
    if await thumbnail(for: item, api: api, isPrefetch: true) == nil,
      !Task.isCancelled, generation == cacheGeneration, libraryScanID == scanID,
      revision == libraryReloadRevision {
      backgroundFailedUntil[identity.key] = Date().addingTimeInterval(300)
    }
  }

  /// Reload wakes an idle walk without cancelling active/shared card requests.
  /// During a walk, finish the current traversal and then check missing items again.
  func retryMissingThumbnails() {
    libraryReloadRevision &+= 1
    libraryIdleWait?.task.cancel()
    failedUntil.removeAll()
    backgroundFailedUntil.removeAll()
    frameAttempts.removeAll()
    frameFailedUntil.removeAll()
  }

  func waitForLibraryRescan(after revision: Int) async {
    guard !Task.isCancelled, revision == libraryReloadRevision else { return }
    let id = UUID()
    let task = Task { do { try await Task.sleep(for: .seconds(300)) } catch {} }
    libraryIdleWait?.task.cancel()
    libraryIdleWait = (id, task)
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    if libraryIdleWait?.id == id { libraryIdleWait = nil }
  }

  nonisolated static func boundedLibraryPage(
    seconds: Double, operation: @escaping @Sendable () async -> ThumbnailLibraryPage?
  ) async -> ThumbnailLibraryPage? {
    let completion = ArtworkCompletion<ThumbnailLibraryPage>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        let worker = Task {
          guard !Task.isCancelled else { completion.finish(nil); return }
          completion.finish(await operation())
        }
        let timeout = Task {
          do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
          completion.finish(nil)
        }
        completion.attach([worker, timeout])
      }
    } onCancel: { completion.finish(nil) }
  }

  func suspendNetwork(for owner: UUID) {
    guard !Task.isCancelled, !endedPlaybackOwners.contains(owner), playbackOwners.insert(owner).inserted else { return }
    for work in inFlight.values { work.task.cancel() }
    inFlight.removeAll()
    directoryWork?.task.cancel()
  }

  func queuedRequestCounts() -> (visible: Int, prefetch: Int) {
    (slotWaiters.filter { !$0.isPrefetch }.count, slotWaiters.filter(\.isPrefetch).count)
  }

  func resumeNetwork(for owner: UUID) {
    endedPlaybackOwners.insert(owner)
    playbackOwners.remove(owner)
    drainWaiters()
  }

  @discardableResult
  func storeGeneratedThumbnail(_ image: UIImage, for item: CloudItem) async -> Bool {
    let identity = identity(for: item), generation = cacheGeneration
    cacheInMemory(image, key: identity.key, pixels: 640)
    return await imageWorker.persist(image: image, data: nil, identity: identity, generation: generation)
  }

  func setGridInteraction(_ interacting: Bool, owner: UUID) {
    if interacting {
      gridOwners.insert(owner)
      for work in inFlight.values where work.isPrefetch && activeFrameSlots.contains(work.id) { work.task.cancel() }
    } else { gridOwners.remove(owner) }
    drainWaiters()
  }

  /// A test/termination barrier; visible consumers never wait for persistence.
  func flushPersistence() async {
    while let task = persistenceTask { await task.value }
  }

  func cacheUsageBytes() async -> Int64 {
    let store = disk
    return await Task.detached(priority: .utility) { store.usageBytes() }.value
  }

  @discardableResult
  func clearCache() async -> Bool {
    cacheGeneration = UUID()
    libraryScanID = UUID()
    libraryIdleWait?.task.cancel()
    directoryWork?.task.cancel()
    backgroundFailedUntil.removeAll()
    for work in inFlight.values { work.task.cancel() }
    inFlight.removeAll()
    failedUntil.removeAll()
    frameAttempts.removeAll()
    frameFailedUntil.removeAll()
    memoryCache.removeAllObjects()
    pendingWrites.removeAll(); writeOrder.removeAll()
    badURLs.removeAll()
    return await imageWorker.reset(generation: cacheGeneration, clear: true)
  }

  /// Cancel work tied to the previous provider while retaining durable artwork.
  /// A provider-specific namespace prevents the next source from reading it.
  func resetForSourceChange() async {
    cacheGeneration = UUID()
    libraryScanID = UUID()
    libraryIdleWait?.task.cancel()
    directoryWork?.task.cancel()
    backgroundFailedUntil.removeAll()
    for work in inFlight.values { work.task.cancel() }
    inFlight.removeAll()
    failedUntil.removeAll()
    frameAttempts.removeAll()
    frameFailedUntil.removeAll()
    memoryCache.removeAllObjects()
    memoryCache.namespaceSnapshot = nil
    for waiter in slotWaiters { waiter.continuation.resume(returning: false) }
    slotWaiters.removeAll()
    activeSlots.removeAll()
    activeFrameSlots.removeAll()
    activePrefetchSlots.removeAll(); activePrefetchFrameSlots.removeAll()
    pendingWrites.removeAll(); writeOrder.removeAll(); badURLs.removeAll()
    _ = await imageWorker.reset(generation: cacheGeneration, clear: false)
  }

  private func localImage(_ identity: ArtworkIdentity, maximumPixelSize: Int, generation: UUID) async -> UIImage? {
    if let image = memoryCache.suitable(forKey: identity.key as NSString, pixels: maximumPixelSize) { return image }
    guard let image = await imageWorker.local(identity, pixels: maximumPixelSize, generation: generation),
      !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() else { return nil }
    cacheInMemory(image, key: identity.key, pixels: maximumPixelSize)
    return image
  }

  private func enqueuePersistence(_ image: UIImage, data: Data?, identity: ArtworkIdentity, generation: UUID) {
    let write = PendingWrite(identity: identity, image: image, data: data, generation: generation)
    // Queue memory and concurrency are bounded; do not let a library scan retain
    // hundreds of images. A dropped write can be filled by a later cache miss.
    if pendingWrites[identity.key] == nil {
      guard writeOrder.count < 32,
        pendingWrites.values.reduce(0, { $0 + $1.cost }) + write.cost <= 32 * 1_024 * 1_024 else {
        GridArtworkTrace.event("persist-deferred", id: identity.key); return
      }
      writeOrder.append(identity.key)
    }
    pendingWrites[identity.key] = write
    guard persistenceTask == nil else { return }
    let id = UUID()
    persistenceID = id
    persistenceTask = Task(priority: .utility) { [self] in
      // Yield delivery first; heavy work is isolated on the image worker actor.
      await Task.yield()
      await drainPersistence(id: id)
    }
  }

  private func drainPersistence(id: UUID) async {
    while !writeOrder.isEmpty {
      let key = writeOrder.removeFirst()
      guard let write = pendingWrites.removeValue(forKey: key), write.generation == cacheGeneration else { continue }
      _ = await imageWorker.persist(image: write.image, data: write.data,
        identity: write.identity, generation: write.generation)
    }
    if persistenceID == id { persistenceTask = nil; persistenceID = nil }
  }

  private func load(
    _ item: CloudItem, identity: ArtworkIdentity, api: APIClient, generation: UUID, workID: UUID, isPrefetch: Bool, pixels: Int
  ) async -> UIImage? {
    if let image = await localImage(identity, maximumPixelSize: pixels, generation: generation) { return image }
    let queued = ProcessInfo.processInfo.systemUptime
    guard await acquireSlot(workID, isPrefetch: inFlight[identity.key]?.isPrefetch ?? isPrefetch) else { return nil }
    GridArtworkTrace.event("queue", id: identity.key, detail: "prefetch=\(isPrefetch)", since: queued)
    var holdsNetworkSlot = true
    defer { if holdsNetworkSlot { releaseSlot(workID) } }
    guard !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() else { return nil }
    let artifact = await Self.boundedResult(seconds: timing.artworkSeconds) { [self] in
      if let loader {
        guard let image = await loader(item, api) else { return nil }
        return LoadedArtwork(image: image, data: nil)
      }
      return await loadNetworkArtwork(for: item, identity: identity, api: api, pixels: pixels, generation: generation)
    }
    var image = artifact?.image
    let wantsFrame = image == nil && item.isVideo && !item.isDiscImage &&
      (loader == nil || frameLoader != nil || sourceFrameLoader != nil) &&
      canRetryFrame(identity.key, isPrefetch: isPrefetch)
    var sourcePlan = SourcePlan(sources: [], blocked: false)
    if wantsFrame, frameLoader == nil {
      // URL lookup uses a network lane, never a decoder lane. Slow 115 address
      // resolution must not consume the frame deadline or both frame slots.
      sourcePlan = await resolveFrameSources(item, identity: identity, api: api, fallback: nil)
    }
    releaseSlot(workID)
    holdsNetworkSlot = false
    if wantsFrame, !Task.isCancelled, generation == cacheGeneration {
      let attempt = frameAttempts[identity.key, default: 0]
      if frameAttempts.count > 1_024 { frameAttempts.removeAll() }
      frameAttempts[identity.key] = min(attempt + 1, 2)
      let budgets = timing.frameSeconds.isEmpty ? [15.0] : timing.frameSeconds
      var remaining = max(0.001, budgets[min(attempt, budgets.count - 1)])
      let candidateBudget = timing.candidateSeconds * pow(2.0, Double(min(attempt, 2)))
      if frameLoader != nil {
        let result = await frameCandidate(nil, item: item, identity: identity, api: api,
          generation: generation, workID: workID, isPrefetch: isPrefetch, seconds: remaining)
        image = result.image
      } else {
        for source in sourcePlan.sources {
          guard !Task.isCancelled, generation == cacheGeneration, remaining > 0 else { break }
          let result = await frameCandidate(source, item: item, identity: identity, api: api,
            generation: generation, workID: workID, isPrefetch: isPrefetch,
            seconds: source.isOriginal ? remaining : min(candidateBudget, remaining))
          remaining -= result.elapsed
          image = result.image
          if image != nil { break }
        }
        if image == nil, !sourcePlan.blocked, !sourcePlan.sources.isEmpty,
          !sourcePlan.sources.contains(where: \.isOriginal), remaining > 0,
          !Task.isCancelled, generation == cacheGeneration {
          // Only resolve the original after available transcodes fail. Release
          // decoder resources while waiting for that second address lookup.
          if await acquireSlot(workID, isPrefetch: inFlight[identity.key]?.isPrefetch ?? isPrefetch) {
            let fallback = await resolveFrameSources(item, identity: identity, api: api, fallback: sourcePlan.sources)
            releaseSlot(workID)
            sourcePlan.blocked = fallback.blocked
            if let source = fallback.sources.first, !Task.isCancelled, generation == cacheGeneration {
              image = await frameCandidate(source, item: item, identity: identity, api: api,
                generation: generation, workID: workID, isPrefetch: isPrefetch,
                seconds: remaining).image
            }
          }
        }
      }
      if image == nil, !Task.isCancelled, generation == cacheGeneration {
        if frameFailedUntil.count > 1_024 { frameFailedUntil.removeAll() }
        let prefetch = inFlight[identity.key]?.isPrefetch ?? isPrefetch
        let delay = sourcePlan.blocked ? 300.0 : Double([5, 15, 30][min(attempt, 2)])
        frameFailedUntil[identity.key] = FrameFailure(until: now().addingTimeInterval(delay),
          wasPrefetch: prefetch, blocked: sourcePlan.blocked)
        GridArtworkTrace.event("frame-retry", id: identity.key,
          detail: "reason=\(sourcePlan.blocked ? "auth-or-rate-limit" : "temporary-or-unavailable") delay=\(delay) prefetch=\(prefetch)")
      }
    }
    guard !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace(),
      inFlight[identity.key]?.id == workID, let image else { return nil }
    failedUntil[identity.key] = nil
    frameAttempts[identity.key] = nil
    frameFailedUntil[identity.key] = nil
    cacheInMemory(image, key: identity.key, pixels: artifact?.data == nil ? 960 : pixels)
    enqueuePersistence(image, data: artifact?.data, identity: identity, generation: generation)
    return image
  }

  private func canRetryFrame(_ key: String, isPrefetch: Bool) -> Bool {
    guard let failure = frameFailedUntil[key], failure.until > now() else { return true }
    let prefetch = inFlight[key]?.isPrefetch ?? isPrefetch
    return failure.wasPrefetch && !prefetch && !failure.blocked
  }

  private struct SourcePlan: Sendable { var sources: [VideoSource]; var blocked: Bool }

  private func resolveFrameSources(_ item: CloudItem, identity: ArtworkIdentity,
    api: APIClient, fallback: [VideoSource]?) async -> SourcePlan {
    let started = ProcessInfo.processInfo.systemUptime
    let completion = ArtworkCompletion<SourcePlan>()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        let worker = Task {
          do {
            let sources: [VideoSource]
            if let fallback {
              let candidate = try await api.thumbnailFallbackSource(for: item, attempted: fallback)
              if let source = candidate {
                sources = [source]
              } else { sources = [] }
            } else { sources = try await api.thumbnailSources(for: item) }
            completion.finish(SourcePlan(sources: sources, blocked: false))
          } catch let error as CloudProviderError {
            let blocked: Bool
            switch error {
            case .authenticationRequired, .rateLimited: blocked = true
            default: blocked = false
            }
            completion.finish(SourcePlan(sources: [], blocked: blocked))
          } catch { completion.finish(SourcePlan(sources: [], blocked: false)) }
        }
        let timeout = Task {
          do { try await Task.sleep(for: .seconds(timing.sourceSeconds)) } catch { return }
          completion.finish(nil)
        }
        completion.attach([worker, timeout])
      }
    } onCancel: { completion.finish(nil) }
    GridArtworkTrace.event("frame-source", id: identity.key,
      detail: "fallback=\(fallback != nil) candidates=\(result?.sources.count ?? 0) blocked=\(result?.blocked ?? false)", since: started)
    return result ?? SourcePlan(sources: [], blocked: false)
  }

  private func frameCandidate(_ source: VideoSource?, item: CloudItem, identity: ArtworkIdentity,
    api: APIClient, generation: UUID, workID: UUID, isPrefetch: Bool, seconds: Double
  ) async -> (image: UIImage?, elapsed: Double) {
    guard !Task.isCancelled, generation == cacheGeneration,
      await acquireSlot(workID, isPrefetch: inFlight[identity.key]?.isPrefetch ?? isPrefetch, isFrame: true) else { return (nil, 0) }
    defer { releaseSlot(workID, isFrame: true) }
    guard !Task.isCancelled, generation == cacheGeneration else { return (nil, 0) }
    let frameLoader = self.frameLoader, sourceLoader = sourceFrameLoader
    let started = ProcessInfo.processInfo.systemUptime
    let image = await Self.boundedArtwork(seconds: max(0.001, seconds)) {
      if let frameLoader { return await frameLoader(item, api) }
      guard let source else { return nil }
      if let sourceLoader { return await sourceLoader(source) }
      return await Self.frameThumbnail(source: source)
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    GridArtworkTrace.event("frame-candidate", id: identity.key,
      detail: "kind=\(source.map { $0.isOriginal ? "original" : "transcoded" } ?? "injected") success=\(image != nil)", since: started)
    return (image, elapsed)
  }

  private func loadNetworkArtwork(for item: CloudItem, identity: ArtworkIdentity, api: APIClient, pixels: Int, generation: UUID) async -> LoadedArtwork? {
    if let url = item.thumbnailURL,
      let result = await remoteThumbnail(at: url, identity: identity, pixels: pixels, generation: generation) { return result }
    guard !Task.isCancelled else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    GridArtworkTrace.event("source-fallback", id: identity.key)
    if item.isPhoto {
      guard let source = try? await api.photoSource(for: item), !Task.isCancelled else { return nil }
      GridArtworkTrace.event("source-resolution", id: identity.key, since: started)
      return await remoteThumbnail(at: source.url, headers: source.headers, identity: identity, pixels: pixels, generation: generation)
    }
    let url = await api.serverThumbnailURL(for: item)
    GridArtworkTrace.event("source-resolution", id: identity.key, since: started)
    if let url, url != item.thumbnailURL,
      let result = await remoteThumbnail(at: url, identity: identity, pixels: pixels, generation: generation) { return result }
    guard !Task.isCancelled, let data = await api.posterData(for: item), data.count <= 16_000_000,
      let image = await imageWorker.decode(data, identity: identity, pixels: pixels, generation: generation) else { return nil }
    return LoadedArtwork(image: image, data: data)
  }

  private struct LoadedArtwork { let image: UIImage; let data: Data? }
  private nonisolated static func boundedResult(seconds: Double,
    operation: @escaping @Sendable () async -> LoadedArtwork?) async -> LoadedArtwork? {
    let completion = ArtworkCompletion<LoadedArtwork>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        let worker = Task { completion.finish(await operation()) }
        let timeout = Task {
          do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
          completion.finish(nil)
        }
        completion.attach([worker, timeout])
      }
    } onCancel: { completion.finish(nil) }
  }

  typealias ArtworkOperation = @Sendable () async -> UIImage?

  nonisolated static func firstAvailableArtwork(_ operations: [ArtworkOperation]) async -> UIImage? {
    guard !operations.isEmpty else { return nil }
    let completion = ArtworkCompletion<UIImage>(remaining: operations.count)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        let tasks = operations.map { operation in
          Task {
            guard !Task.isCancelled else { completion.candidateFinished(nil); return }
            completion.candidateFinished(await operation())
          }
        }
        completion.attach(tasks)
      }
    } onCancel: { completion.finish(nil) }
  }

  /// Unlike a task-group race, this does not await an uncooperative loser.
  nonisolated static func boundedArtwork(
    seconds: Double, operation: @escaping @Sendable () async -> UIImage?
  ) async -> UIImage? {
    let completion = ArtworkCompletion<UIImage>()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        let worker = Task {
          guard !Task.isCancelled else { completion.finish(nil); return }
          completion.finish(await operation())
        }
        let timeout = Task {
          do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
          catch { return }
          completion.finish(nil)
        }
        completion.attach([worker, timeout])
      }
    } onCancel: { completion.finish(nil) }
  }

  nonisolated static func frameThumbnail(source: VideoSource) async -> UIImage? {
    let probe = ThumbnailFrameProbe(source: source)
    let timeout = Task {
      do { try await Task.sleep(nanoseconds: 60_000_000_000) }
      catch { return }
      probe.cancel()
    }
    defer { timeout.cancel() }
    return await withTaskCancellationHandler {
      guard !Task.isCancelled else { return nil }
      // No isPlayable/duration preflight or percentage seek: get a near-start
      // frame without loading the tail index just to calculate the target time.
      for seconds in [0.5, 0.0] {
        guard !Task.isCancelled, !probe.isCancelled else { return nil }
        let generated = try? await probe.generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        if let generated {
          guard !Task.isCancelled, !probe.isCancelled else { return nil }
          return UIImage(cgImage: generated.image)
        }
      }
      return nil
    } onCancel: {
      probe.cancel()
    }
  }

  private func remoteThumbnail(at url: URL, headers: [String: String] = [:], identity: ArtworkIdentity,
    pixels: Int, generation: UUID) async -> LoadedArtwork? {
    if let until = badURLs[url], until > Date() { return nil }
    var request = URLRequest(url: url)
    request.cachePolicy = .useProtocolCachePolicy
    request.timeoutInterval = 5
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let started = ProcessInfo.processInfo.systemUptime
    GridArtworkTrace.event("network-request", id: identity.key)
    do {
      let data = try await ArtworkByteReceiver.receive(request, session: imageSession, limit: 16_000_000)
      GridArtworkTrace.event("network-receive", id: identity.key, detail: "bytes=\(data.count)", since: started)
      guard !Task.isCancelled, let image = await imageWorker.decode(data, identity: identity, pixels: pixels, generation: generation) else { return nil }
      return LoadedArtwork(image: image, data: data)
    } catch {
      if !Task.isCancelled {
        if badURLs.count > 256 { badURLs.removeAll() }
        badURLs[url] = Date().addingTimeInterval(30)
      }
      return nil
    }
  }

  private func cacheInMemory(_ image: UIImage, key: String, pixels: Int) {
    let width = max(Int(image.size.width * image.scale), 1)
    let height = max(Int(image.size.height * image.scale), 1)
    memoryCache.setObject(image, forKey: key as NSString, cost: min(width * height * 4, 16 * 1_024 * 1_024), pixels: pixels)
  }

  private func cancelClient(_ client: UUID, key: String, workID: UUID) {
    guard var work = inFlight[key], work.id == workID else { return }
    work.clients.removeValue(forKey:client)
    if work.clients.isEmpty {
      work.task.cancel()
      inFlight[key] = nil
    } else {
      let previousPriority=work.isPrefetch
      work.isPrefetch=work.clients.values.allSatisfy { $0 }
      inFlight[key] = work
      if previousPriority != work.isPrefetch { updatePriority(work) }
    }
  }

  /// Priority follows the remaining consumers, including already active lanes.
  /// A promoted cover gives its speculative slot back immediately. If its last
  /// visible card disappears, keep only the bounded background allocation;
  /// interested prefetch consumers requeue a cancelled worker without failure.
  private func updatePriority(_ work:Work) {
    for index in slotWaiters.indices where slotWaiters[index].id==work.id {
      slotWaiters[index].isPrefetch=work.isPrefetch
    }
    var mustYield=false
    if activeSlots.contains(work.id) {
      if work.isPrefetch {
        if !activePrefetchSlots.contains(work.id),activePrefetchSlots.count>=maximumNetworkJobs-1 { mustYield=true }
        else { activePrefetchSlots.insert(work.id) }
      } else { activePrefetchSlots.remove(work.id) }
    }
    if activeFrameSlots.contains(work.id) {
      if work.isPrefetch {
        if !gridOwners.isEmpty || (!activePrefetchFrameSlots.contains(work.id) && !activePrefetchFrameSlots.isEmpty) { mustYield=true }
        else { activePrefetchFrameSlots.insert(work.id) }
      } else { activePrefetchFrameSlots.remove(work.id) }
    }
    if mustYield { work.task.cancel() }
    drainWaiters()
  }

  private func acquireSlot(_ id: UUID, isPrefetch: Bool, isFrame: Bool = false) async -> Bool {
    guard !Task.isCancelled else { return false }
    if canAcquireSlot(isFrame: isFrame, isPrefetch: isPrefetch) {
      if isPrefetch { if isFrame { activePrefetchFrameSlots.insert(id) } else { activePrefetchSlots.insert(id) } }
      if isFrame { activeFrameSlots.insert(id) }
      else { activeSlots.insert(id) }
      return true
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(returning: false) }
        else { slotWaiters.append(SlotWaiter(id: id, continuation: continuation, isPrefetch: isPrefetch, isFrame: isFrame)) }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
    slotWaiters.remove(at: index).continuation.resume(returning: false)
  }

  private func canAcquireSlot(isFrame: Bool, isPrefetch: Bool) -> Bool {
    guard playbackOwners.isEmpty else { return false }
    if isPrefetch {
      if isFrame { return gridOwners.isEmpty && activePrefetchFrameSlots.count < 1 && activeFrameSlots.count < maximumFrameJobs }
      return activePrefetchSlots.count < maximumNetworkJobs - 1 && activeSlots.count < maximumNetworkJobs
    }
    return isFrame ? activeFrameSlots.count < maximumFrameJobs : activeSlots.count < maximumNetworkJobs
  }

  private func releaseSlot(_ id: UUID, isFrame: Bool = false) {
    if isFrame { activePrefetchFrameSlots.remove(id) } else { activePrefetchSlots.remove(id) }
    if isFrame { activeFrameSlots.remove(id) }
    else { activeSlots.remove(id) }
    drainWaiters()
  }

  private func drainWaiters() {
    while playbackOwners.isEmpty {
      let eligible = slotWaiters.indices.filter { canAcquireSlot(isFrame: slotWaiters[$0].isFrame, isPrefetch: slotWaiters[$0].isPrefetch) }
      guard let index = eligible.first(where: { !slotWaiters[$0].isPrefetch }) ?? eligible.first else { return }
      let waiter = slotWaiters.remove(at: index)
      if waiter.isPrefetch {
        if waiter.isFrame { activePrefetchFrameSlots.insert(waiter.id) } else { activePrefetchSlots.insert(waiter.id) }
      }
      if waiter.isFrame { activeFrameSlots.insert(waiter.id) }
      else { activeSlots.insert(waiter.id) }
      waiter.continuation.resume(returning: true)
    }
  }
}

/// Only the generation task accesses the generator; cancellation handlers call
/// AVFoundation's cancellation APIs. The cancelled bit is protected by a lock.
private final class ThumbnailFrameProbe: @unchecked Sendable {
  let asset: AVURLAsset
  let generator: AVAssetImageGenerator
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  init(source: VideoSource) {
    var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
    if !source.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = source.headers }
    asset = AVURLAsset(url: source.url, options: options)
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 360)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
    generator.cancelAllCGImageGeneration()
    asset.cancelLoading()
  }
}

/// Exactly-once completion, including cancellation before continuation installation.
private final class ArtworkCompletion<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var result: Value?
  private var continuation: CheckedContinuation<Value?, Never>?
  private var tasks: [Task<Void, Never>] = []
  private var remaining: Int

  init(remaining: Int = 1) { self.remaining = remaining }

  func candidateFinished(_ image: Value?) {
    if let image { finish(image); return }
    lock.lock()
    remaining -= 1
    let exhausted = remaining == 0
    lock.unlock()
    if exhausted { finish(nil) }
  }

  func install(_ continuation: CheckedContinuation<Value?, Never>) {
    lock.lock()
    if finished {
      let result = result
      lock.unlock()
      continuation.resume(returning: result)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  func attach(_ tasks: [Task<Void, Never>]) {
    lock.lock()
    let shouldCancel = finished
    if !shouldCancel { self.tasks = tasks }
    lock.unlock()
    if shouldCancel { tasks.forEach { $0.cancel() } }
  }

  func finish(_ image: Value?) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    result = image
    let continuation = continuation
    self.continuation = nil
    let tasks = tasks
    self.tasks = []
    lock.unlock()
    continuation?.resume(returning: image)
    tasks.forEach { $0.cancel() }
  }
}

/// NSCache provides its own synchronization. Keep raw cache mutation out of views.
private final class ArtworkMemoryCache: @unchecked Sendable {
  private final class Entry {
    let image: UIImage; let pixels: Int
    init(_ image: UIImage, _ pixels: Int) { self.image = image; self.pixels = pixels }
  }
  private let cache = NSCache<NSString, Entry>()
  private let lock = NSLock()
  private var storedNamespace: String?
  var namespaceSnapshot: String? {
    get { lock.lock(); defer { lock.unlock() }; return storedNamespace }
    set { lock.lock(); storedNamespace = newValue; lock.unlock() }
  }
  var countLimit: Int { get { cache.countLimit } set { cache.countLimit = newValue } }
  var totalCostLimit: Int { get { cache.totalCostLimit } set { cache.totalCostLimit = newValue } }
  func object(forKey key: NSString) -> UIImage? { cache.object(forKey: key)?.image }
  func suitable(forKey key: NSString, pixels: Int) -> UIImage? {
    guard let entry = cache.object(forKey: key), entry.pixels >= pixels else { return nil }
    return entry.image
  }
  func setObject(_ image: UIImage, forKey key: NSString, cost: Int, pixels: Int) {
    lock.lock(); defer { lock.unlock() }
    if let existing = cache.object(forKey: key), existing.pixels >= pixels { return }
    cache.setObject(Entry(image, pixels), forKey: key, cost: cost)
  }
  func removeAllObjects() { lock.lock(); defer { lock.unlock() }; cache.removeAllObjects() }
}


enum ArtworkSizeTier {
  static func pixels(for requested: Int) -> Int {
    if requested <= 320 { return 320 }
    if requested <= 640 { return 640 }
    return 960
  }
}

/// A separate serial executor bounds decode/encode/disk concurrency to one.
/// There is no synchronous I/O or JPEG compression on ThumbnailService's actor.
private actor ArtworkImageWorker {
  let disk: ArtworkDiskStore
  private var generation: UUID
  private let recentSources = NSCache<NSString, NSData>()
  init(disk: ArtworkDiskStore, generation: UUID) {
    self.disk = disk; self.generation = generation
    recentSources.countLimit = 24
    recentSources.totalCostLimit = 24 * 1_024 * 1_024
  }
  func reset(generation: UUID, clear: Bool) -> Bool {
    self.generation = generation
    recentSources.removeAllObjects()
    do { if clear { try disk.clear() }; return true } catch { return false }
  }
  func contains(_ identity: ArtworkIdentity, generation: UUID) -> Bool {
    guard self.generation == generation else { return false }
    if recentSources.object(forKey: identity.key as NSString) != nil { return true }
    guard let data = try? disk.read(identity), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
  }
  func local(_ identity: ArtworkIdentity, pixels: Int, generation: UUID, queuedAt: Double = ProcessInfo.processInfo.systemUptime) -> UIImage? {
    guard self.generation == generation, !Task.isCancelled else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    GridArtworkTrace.event("disk-queue", id: identity.key, since: queuedAt)
    if let data = recentSources.object(forKey: identity.key as NSString) {
      return decode(data as Data, identity: identity, pixels: pixels, generation: generation)
    }
    guard let data = try? disk.read(identity) else { return nil }
    GridArtworkTrace.event("disk-read", id: identity.key, detail: "bytes=\(data.count)", since: started)
    guard let image = decode(data, identity: identity, pixels: pixels, generation: generation) else {
      if !Task.isCancelled { disk.remove(identity) }
      return nil
    }
    GridArtworkTrace.event("disk-hit", id: identity.key)
    return image
  }
  func decode(_ data: Data, identity: ArtworkIdentity, pixels: Int, generation: UUID, queuedAt: Double = ProcessInfo.processInfo.systemUptime) -> UIImage? {
    guard self.generation == generation, !Task.isCancelled else { return nil }
    let started = ProcessInfo.processInfo.systemUptime
    GridArtworkTrace.event("decode-queue", id: identity.key, since: queuedAt)
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: pixels,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    recentSources.setObject(data as NSData, forKey: identity.key as NSString, cost: data.count)
    GridArtworkTrace.event("decode", id: identity.key, detail: "pixels=\(pixels)", since: started)
    return UIImage(cgImage: cg)
  }
  func persist(image: UIImage, data: Data?, identity: ArtworkIdentity, generation: UUID) -> Bool {
    guard self.generation == generation else { return false }
    let started = ProcessInfo.processInfo.systemUptime
    // Keep compressed server material for future larger decodes. Generated
    // frames retain the original JPEG policy. A dense decode never replaces it.
    guard let encoded = data ?? image.jpegData(compressionQuality: 0.80) else { return false }
    do {
      if let existing = try disk.read(identity), Self.extent(existing) > Self.extent(encoded) { return true }
      try disk.write(encoded, for: identity)
      GridArtworkTrace.event("persist", id: identity.key, detail: "bytes=\(encoded.count)", since: started)
      return true
    } catch {
      GridArtworkTrace.event("persist-failed", id: identity.key, since: started)
      return false
    }
  }
  private static func extent(_ data: Data) -> Int {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 0 }
    return max((info[kCGImagePropertyPixelWidth] as? Int) ?? 0, (info[kCGImagePropertyPixelHeight] as? Int) ?? 0)
  }
}

/// Reuse the image session's connections and receive bounded chunks instead of
/// awaiting/appending each byte. Headers and streamed bodies share one budget.
enum ArtworkByteReceiver {
  static func receive(_ request: URLRequest, session: URLSession, limit: Int) async throws -> Data {
    guard limit>0 else { throw URLError(.dataLengthExceedsMaximum) }
    let receiver=ArtworkChunkReceiver(limit:limit)
    defer { withExtendedLifetime(receiver) {} }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        receiver.start(request,session:session,continuation:continuation)
      }
    } onCancel: { receiver.cancel() }
  }
}

/// Task-specific delegates preserve the existing session and its request pool.
/// The lock also covers cancellation before installation and late callbacks.
private final class ArtworkChunkReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock=NSLock(), limit:Int
  private var data=Data(), accepted=false, completed=false
  private var continuation:CheckedContinuation<Data,Error>?
  private var task:URLSessionDataTask?
  init(limit:Int) { self.limit=limit; super.init() }
  func start(_ request:URLRequest,session:URLSession,continuation:CheckedContinuation<Data,Error>) {
    lock.lock()
    guard !completed else { lock.unlock(); continuation.resume(throwing:URLError(.cancelled)); return }
    let task=session.dataTask(with:request)
    task.delegate=self
    self.task=task; self.continuation=continuation
    lock.unlock(); task.resume()
  }
  func cancel() { finish(URLError(.cancelled)) }
  private func finish(_ error:Error?) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed=true
    let continuation=self.continuation, task=self.task
    self.continuation=nil; self.task=nil
    let result=data; data=Data()
    lock.unlock()
    if let error { task?.cancel(); continuation?.resume(throwing:error) }
    else { continuation?.resume(returning:result) }
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,
    completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
    guard let http=response as? HTTPURLResponse,(200...299).contains(http.statusCode),
      response.expectedContentLength<=Int64(limit),let mime=response.mimeType?.lowercased(),
      mime.hasPrefix("image/") || mime=="application/octet-stream" else {
      completionHandler(.cancel); finish(URLError(.badServerResponse)); return
    }
    lock.lock()
    let allowed = !completed
    if allowed {
      accepted=true
      data.reserveCapacity(min(limit,max(0,Int(response.expectedContentLength))))
    }
    lock.unlock(); completionHandler(allowed ? .allow : .cancel)
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive bytes:Data) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    guard accepted,bytes.count<=limit-data.count else {
      lock.unlock(); finish(URLError(.dataLengthExceedsMaximum)); return
    }
    data.append(bytes); lock.unlock()
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    lock.lock(); let accepted=self.accepted; lock.unlock()
    finish(error ?? (accepted ? nil : URLError(.badServerResponse)))
  }
}

/// Opt in with CINEVA_GRID_TRACE=1 in the Debug scheme. No URLs or raw media IDs.
/// Correlate timestamped stages with Points of Interest / Time Profiler and
/// Allocations. Release builds neither format event details nor emit logs.
enum GridArtworkTrace {
  private static let enabled: Bool = {
    #if DEBUG
    return ProcessInfo.processInfo.environment["CINEVA_GRID_TRACE"] == "1"
    #else
    return false
    #endif
  }()
  private static let scenario = ProcessInfo.processInfo.environment["CINEVA_ARTWORK_SCENARIO"] ?? "unspecified"
  private static let log = Logger(subsystem: "com.xiaocai.gallery115", category: "GridArtworkTiming")
  static func event(_ stage: String, id: String, detail: @autoclosure () -> String = "", since start: Double? = nil) {
    #if DEBUG
    guard enabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = start.map { (now - $0) * 1000 } ?? 0
    let key = ArtworkIdentity.digest(id).prefix(12)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    let resident = status == KERN_SUCCESS ? info.resident_size : 0
    let message = detail()
    log.debug("scenario=\(scenario, privacy: .public) stage=\(stage, privacy: .public) id=\(key, privacy: .public) t=\(now) ms=\(elapsed) resident=\(resident) \(message, privacy: .public)")
    #endif
  }
}
