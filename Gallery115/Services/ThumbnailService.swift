import AVFoundation
import Foundation
import ImageIO
import OSLog
import UIKit

/// Local-first artwork; a small bounded pool fills visible rows while playback has priority.
actor ThumbnailService {
  typealias Loader = @Sendable (CloudItem, APIClient) async -> UIImage?
  private struct Work {
    let id: UUID
    let task: Task<UIImage?, Never>
    var clients: Set<UUID>
  }
  private struct SlotWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let disk: ArtworkDiskStore
  private let namespace: @Sendable () -> String
  private let loader: Loader?
  private let memoryCache = NSCache<NSString, UIImage>()
  private let logger = Logger(subsystem: "com.xiaocai.gallery115", category: "Artwork")
  private var inFlight: [String: Work] = [:]
  private var failedUntil: [String: Date] = [:]
  private var activeSlots: Set<UUID> = []
  private var slotWaiters: [SlotWaiter] = []
  private var playbackOwners: Set<UUID> = []
  private var cacheGeneration = UUID()
  private let maximumNetworkJobs = 3

  init(
    disk: ArtworkDiskStore = ArtworkDiskStore(),
    namespace: @escaping @Sendable () -> String = ThumbnailService.currentNamespace,
    loader: Loader? = nil
  ) {
    self.disk = disk
    self.namespace = namespace
    self.loader = loader
    memoryCache.countLimit = 160
    memoryCache.totalCostLimit = 72 * 1_024 * 1_024
  }

  nonisolated static func currentNamespace() -> String {
    guard let config = WebDAVCredentialStore.shared.configuration else { return "unconfigured" }
    // Full endpoint includes scheme, port and base path. Never include passwords.
    return [config.normalizedWebDAVURL?.absoluteString ?? config.serverURL,
            config.username, config.normalizedRootPath].map { "\($0.utf8.count):\($0)" }.joined()
  }

  private func identity(for item: CloudItem) -> ArtworkIdentity {
    ArtworkIdentity(namespace: namespace(), itemID: item.id, size: item.size,
                    modifiedAt: item.modifiedAt, legacyKey: item.sha1.isEmpty ? item.id : item.sha1)
  }

  func thumbnail(for item: CloudItem, api: APIClient) async -> UIImage? {
    guard item.isVideo else { return nil }
    let identity = identity(for: item)
    let generation = cacheGeneration
    while !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() {
      if let image = localImage(identity) { return image }
      if let retry = failedUntil[identity.key], retry > Date() { return nil }

      let clientID = UUID()
      let work: Work
      if var existing = inFlight[identity.key] {
        existing.clients.insert(clientID)
        inFlight[identity.key] = existing
        work = existing
      } else {
        let workID = UUID()
        let task = Task<UIImage?, Never> { [weak self] in
          guard let self else { return nil }
          return await self.load(item, identity: identity, api: api, generation: generation, workID: workID)
        }
        work = Work(id: workID, task: task, clients: [clientID])
        inFlight[identity.key] = work
      }

      let result = await withTaskCancellationHandler {
        await work.task.value
      } onCancel: {
        Task { await self.cancelClient(clientID, key: identity.key, workID: work.id) }
      }
      if inFlight[identity.key]?.id == work.id {
        inFlight[identity.key] = nil
        if result == nil, !work.task.isCancelled, generation == cacheGeneration {
          failedUntil[identity.key] = Date().addingTimeInterval(120)
        }
      }
      guard !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() else { return nil }
      // Playback cancellation isn't a failure. Interested cards retry behind
      // the closed gate and resume when the player closes.
      if work.task.isCancelled { continue }
      return result
    }
    return nil
  }

  func generatedThumbnail(for item: CloudItem, api: APIClient) async -> UIImage? {
    await thumbnail(for: item, api: api)
  }

  func prefetch(_ items: [CloudItem], api: APIClient, limit: Int = 12) async {
    // WebDAV items normally have no ready-made thumbnail URL. They still need
    // proactive sidecar/frame generation instead of waiting for each card to
    // appear. The shared slot gate below keeps this bounded and playback-safe.
    let targets = Array(items.lazy.filter(\.isVideo).prefix(max(limit, 0)))
    await withTaskGroup(of: Void.self) { group in
      for item in targets {
        group.addTask { [weak self] in
          guard let self, !Task.isCancelled else { return }
          _ = await self.thumbnail(for: item, api: api)
        }
      }
      await group.waitForAll()
    }
  }

  func suspendNetwork(for owner: UUID) {
    guard playbackOwners.insert(owner).inserted else { return }
    for work in inFlight.values { work.task.cancel() }
    inFlight.removeAll()
  }

  func resumeNetwork(for owner: UUID) {
    playbackOwners.remove(owner)
    drainWaiters()
  }

  @discardableResult
  func storeGeneratedThumbnail(_ image: UIImage, for item: CloudItem) -> Bool {
    persist(image, identity: identity(for: item))
  }

  func cacheUsageBytes() async -> Int64 {
    let store = disk
    return await Task.detached(priority: .utility) { store.usageBytes() }.value
  }

  @discardableResult
  func clearCache() -> Bool {
    cacheGeneration = UUID()
    for work in inFlight.values { work.task.cancel() }
    inFlight.removeAll()
    failedUntil.removeAll()
    memoryCache.removeAllObjects()
    do {
      try disk.clear()
      return true
    } catch {
      logger.error("Unable to clear durable artwork: \(error.localizedDescription, privacy: .private)")
      return false
    }
  }

  private func localImage(_ identity: ArtworkIdentity) -> UIImage? {
    if let image = memoryCache.object(forKey: identity.key as NSString) { return image }
    do {
      guard let data = try disk.read(identity) else { return nil }
      guard let image = downsampledImage(from: data) else {
        disk.remove(identity)
        return nil
      }
      cacheInMemory(image, key: identity.key)
      return image
    } catch {
      logger.error("Unable to read durable artwork: \(error.localizedDescription, privacy: .private)")
      return nil
    }
  }

  private func persist(_ image: UIImage, identity: ArtworkIdentity) -> Bool {
    cacheInMemory(image, key: identity.key)
    guard let data = image.jpegData(compressionQuality: 0.80) else { return false }
    do {
      try disk.write(data, for: identity)
      return true
    } catch {
      logger.error("Unable to persist artwork: \(error.localizedDescription, privacy: .private)")
      return false
    }
  }

  private func load(
    _ item: CloudItem, identity: ArtworkIdentity, api: APIClient, generation: UUID, workID: UUID
  ) async -> UIImage? {
    guard await acquireSlot(workID) else { return nil }
    defer { releaseSlot(workID) }
    guard !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace() else { return nil }
    if let image = localImage(identity) { return image }
    let image: UIImage?
    if let loader {
      image = await loader(item, api)
    } else {
      image = await loadNetworkArtwork(for: item, api: api)
    }
    guard !Task.isCancelled, generation == cacheGeneration, identity.namespace == namespace(),
      let image else { return nil }
    failedUntil[identity.key] = nil
    _ = persist(image, identity: identity)
    return image
  }

  private func loadNetworkArtwork(for item: CloudItem, api: APIClient) async -> UIImage? {
    // The slot covers sidecar discovery too. Previously every visible card could
    // issue PROPFIND requests before it reached the frame-generation semaphore.
    if let url = item.thumbnailURL, let image = await remoteThumbnail(at: url) { return image }
    guard !Task.isCancelled else { return nil }
    if let metadata = await api.localMetadata(for: item), let data = metadata.posterData,
      let image = downsampledImage(from: data) { return image }
    guard !Task.isCancelled, !item.isDiscImage,
      let source = try? await api.videoSources(for: item).first else { return nil }
    guard !Task.isCancelled else { return nil }
    return await Self.frameThumbnail(source: source)
  }

  nonisolated static func frameThumbnail(source: VideoSource) async -> UIImage? {
    let probe = ThumbnailFrameProbe(source: source)
    let timeout = Task {
      do { try await Task.sleep(nanoseconds: 20_000_000_000) }
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

  private func remoteThumbnail(at url: URL) async -> UIImage? {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 12
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      !Task.isCancelled, data.count <= 16_000_000,
      let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
    else { return nil }
    return downsampledImage(from: data)
  }

  private func cacheInMemory(_ image: UIImage, key: String) {
    let width = max(Int(image.size.width * image.scale), 1)
    let height = max(Int(image.size.height * image.scale), 1)
    memoryCache.setObject(image, forKey: key as NSString, cost: min(width * height * 4, 16 * 1_024 * 1_024))
  }

  private func downsampledImage(from data: Data) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 960,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
  }

  private func cancelClient(_ client: UUID, key: String, workID: UUID) {
    guard var work = inFlight[key], work.id == workID else { return }
    work.clients.remove(client)
    if work.clients.isEmpty {
      work.task.cancel()
      inFlight[key] = nil
    } else {
      inFlight[key] = work
    }
  }

  private func acquireSlot(_ id: UUID) async -> Bool {
    guard !Task.isCancelled else { return false }
    if playbackOwners.isEmpty, activeSlots.count < maximumNetworkJobs {
      activeSlots.insert(id)
      return true
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(returning: false) }
        else { slotWaiters.append(SlotWaiter(id: id, continuation: continuation)) }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
    slotWaiters.remove(at: index).continuation.resume(returning: false)
  }

  private func releaseSlot(_ id: UUID) {
    activeSlots.remove(id)
    drainWaiters()
  }

  private func drainWaiters() {
    while playbackOwners.isEmpty, activeSlots.count < maximumNetworkJobs, !slotWaiters.isEmpty {
      let waiter = slotWaiters.removeFirst()
      activeSlots.insert(waiter.id)
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
    generator.maximumSize = CGSize(width: 960, height: 540)
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
