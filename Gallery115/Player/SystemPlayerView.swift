import AVFoundation
import AVKit
import CoreImage
import Observation
import QuartzCore
import SwiftUI
import UIKit

enum PlayerVideoLayout: String, CaseIterable {
  case fit
  case fill

  var gravity: AVLayerVideoGravity {
    switch self {
    case .fit: return .resizeAspect
    case .fill: return .resizeAspectFill
    }
  }

  var title: String {
    switch self {
    case .fit: return "适应屏幕"
    case .fill: return "铺满屏幕"
    }
  }
}

@MainActor
@Observable
final class SystemPlayerPresentationController: NSObject, AVPictureInPictureControllerDelegate {
  private(set) var isPictureInPictureActive = false
  private(set) var isPictureInPictureSupported = AVPictureInPictureController.isPictureInPictureSupported()
  private var pictureInPictureController: AVPictureInPictureController?
  private weak var attachedLayer: AVPlayerLayer?
  private let previewContext = CIContext(options: [.cacheIntermediates: false])

  func attach(playerLayer: AVPlayerLayer) {
    attachedLayer = playerLayer
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      isPictureInPictureSupported = false
      pictureInPictureController = nil
      return
    }

    if pictureInPictureController == nil {
      guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
        isPictureInPictureSupported = false
        return
      }
      controller.delegate = self
      controller.canStartPictureInPictureAutomaticallyFromInline = true
      pictureInPictureController = controller
    }
    isPictureInPictureSupported = true
  }

  func detach(playerLayer: AVPlayerLayer) {
    guard attachedLayer === playerLayer else { return }
    attachedLayer = nil
    if pictureInPictureController?.isPictureInPictureActive == true {
      pictureInPictureController?.stopPictureInPicture()
    }
    pictureInPictureController = nil
    isPictureInPictureActive = false
  }

  func startPictureInPicture() {
    guard let controller = pictureInPictureController,
      AVPictureInPictureController.isPictureInPictureSupported()
    else { return }
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    } else if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    }
  }

  func stopPictureInPicture() {
    pictureInPictureController?.stopPictureInPicture()
  }

  /// Returns the exact frame currently presented by the primary AVPlayerLayer.
  /// This is intentionally sourced from the display layer rather than a separate
  /// AVAssetImageGenerator so timeline scrubbing never shows a thumbnail from a
  /// different timestamp or competes with the remote Range requests used by the
  /// real player.
  func displayedFrameImage(maximumDimension: CGFloat = 420) -> UIImage? {
    guard let pixelBuffer = attachedLayer?.displayedPixelBuffer() else { return nil }

    var image = CIImage(cvPixelBuffer: pixelBuffer)
    let extent = image.extent.integral
    guard extent.width > 0, extent.height > 0 else { return nil }

    let longestSide = max(extent.width, extent.height)
    if maximumDimension > 0, longestSide > maximumDimension {
      let scale = maximumDimension / longestSide
      image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    guard let cgImage = previewContext.createCGImage(image, from: image.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }

  func cacheDisplayedFrame(in previews: TimelinePreviewController, at seconds: Double) {
    guard previews.shouldCapture(at: seconds),
      let buffer = attachedLayer?.displayedPixelBuffer() else { return }
    previews.capture(buffer, at: seconds)
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPictureInPictureActive = true
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPictureInPictureActive = false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    isPictureInPictureActive = false
  }
}

/// Preview decoding never seeks the primary player. Cached frames are looked up
/// synchronously on touch; only a cache miss starts a single coalesced request.
@MainActor
@Observable
final class TimelinePreviewController {
  private(set) var image: UIImage?
  private(set) var imageTime: Double = 0
  private(set) var isActive = false
  @ObservationIgnored private var frames: [Int: Frame] = [:]
  @ObservationIgnored private var order: [Int] = []
  @ObservationIgnored private var cacheBytes = 0
  @ObservationIgnored private var generator: AVAssetImageGenerator?
  @ObservationIgnored private var fallbackGenerator: AVAssetImageGenerator?
  @ObservationIgnored private var sourceIdentity: String?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var requestedTime: Double = 0
  @ObservationIgnored private var requestTask: Task<Void, Never>?
  @ObservationIgnored private var warmRequest = false
  @ObservationIgnored private var allowsWarmup = false
  @ObservationIgnored private var warmSlot = 0
  @ObservationIgnored private var lastWarmAt = Date.distantPast
  @ObservationIgnored private var captureInProgress = false
  @ObservationIgnored private var lastCaptureTime = -Double.infinity
  @ObservationIgnored private var warmFailures = 0

  private struct Frame {
    let image: UIImage
    let time: Double
    let bytes: Int
  }

  func configure(asset: AVAsset, identity: String, allowsWarmup: Bool, fallbackAsset: AVAsset? = nil) {
    guard sourceIdentity != identity else { return }
    cancelRequest()
    sourceIdentity = identity
    self.allowsWarmup = allowsWarmup
    warmFailures = 0
    generator = makeGenerator(asset: asset)
    fallbackGenerator = fallbackAsset.map { makeGenerator(asset: $0) }
  }

  private func makeGenerator(asset: AVAsset) -> AVAssetImageGenerator {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    return generator
  }

  func reset() {
    end()
    generator = nil
    fallbackGenerator = nil
    sourceIdentity = nil
    frames.removeAll()
    order.removeAll()
    cacheBytes = 0
    warmSlot = 0
    lastWarmAt = .distantPast
    lastCaptureTime = -Double.infinity
  }

  func begin(at seconds: Double) {
    cancelRequest()
    isActive = true
    show(at: seconds)
  }

  func show(at seconds: Double) {
    guard isActive, seconds.isFinite else { return }
    requestedTime = max(seconds, 0)
    let frame = nearest(to: requestedTime)
    // A sparse storyboard is explicitly labelled with its actual timestamp.
    // Never hold a completely unrelated frame while waiting on a remote miss.
    image = frame?.image
    imageTime = frame?.time ?? requestedTime
    if let frame, abs(frame.time - requestedTime) <= 0.5 { return }
    guard requestTask == nil else { return }
    requestFrame(warming: false)
  }

  func end(keepImageUntilSeekCompletes: Bool = false) {
    cancelRequest()
    if !keepImageUntilSeekCompletes {
      isActive = false
      image = nil
    }
  }

  private func nearest(to seconds: Double) -> Frame? {
    guard let frame = frames.values.min(by: { abs($0.time - seconds) < abs($1.time - seconds) }),
      abs(frame.time - seconds) <= 30 else { return nil }
    return frame
  }

  private func store(_ image: UIImage, at seconds: Double) {
    guard seconds.isFinite, let cgImage = image.cgImage else { return }
    let key = Int((seconds * 2).rounded())
    let bytes = cgImage.bytesPerRow * cgImage.height
    if let old = frames[key] { cacheBytes -= old.bytes }
    order.removeAll { $0 == key }
    frames[key] = Frame(image: image, time: seconds, bytes: bytes)
    order.append(key)
    cacheBytes += bytes
    while cacheBytes > 32 * 1_024 * 1_024 || order.count > 160 {
      let removed = order.removeFirst()
      if let frame = frames.removeValue(forKey: removed) { cacheBytes -= frame.bytes }
    }
  }

  func shouldCapture(at seconds: Double) -> Bool {
    !isActive && !captureInProgress && seconds.isFinite && abs(seconds - lastCaptureTime) >= 0.5
      && ProcessInfo.processInfo.thermalState == .nominal
      && !ProcessInfo.processInfo.isLowPowerModeEnabled
  }

  func capture(_ buffer: CVPixelBuffer, at seconds: Double) {
    guard shouldCapture(at: seconds) else { return }
    captureInProgress = true
    lastCaptureTime = seconds
    let token = sourceIdentity
    // Reuse an already decoded frame. No second video download, and no image
    // conversion on the main thread. At most one conversion can be in flight.
    Task { @MainActor [weak self] in
      let cgImage = await Task.detached(priority: .utility) {
        let input = CIImage(cvPixelBuffer: buffer)
        let longestSide = max(input.extent.width, input.extent.height)
        guard longestSide > 0 else { return Optional<CGImage>.none }
        let scale = min(480 / longestSide, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return PreviewFrameRenderer.context.createCGImage(small, from: small.extent)
      }.value
      guard let self else { return }
      self.captureInProgress = false
      guard self.sourceIdentity == token, let cgImage else { return }
      self.store(UIImage(cgImage: cgImage), at: seconds)
    }
  }

  func maintain(duration: Double, mayWarm: Bool) {
    guard !isActive else { return }
    let permitted = mayWarm && allowsWarmup && duration > 0
      && ProcessInfo.processInfo.thermalState == .nominal
      && !ProcessInfo.processInfo.isLowPowerModeEnabled
    if !permitted {
      if warmRequest { cancelRequest() }
      return
    }
    guard warmSlot < 48, warmFailures < 2, requestTask == nil,
      Date().timeIntervalSince(lastWarmAt) >= 8 else { return }
    // Remote assets must not opt in: even small transcode seeks can compete
    // with the original's download. Only local files may build a storyboard.
    requestedTime = min(duration * (Double(warmSlot) + 0.5) / 48, max(duration - 0.1, 0))
    warmSlot += 1
    lastWarmAt = Date()
    requestFrame(warming: true)
  }

  private func cancelRequest() {
    generation &+= 1
    requestTask?.cancel()
    requestTask = nil
    generator?.cancelAllCGImageGeneration()
    warmRequest = false
  }

  private func requestFrame(warming: Bool) {
    guard let generator else { return }
    warmRequest = warming
    let generation = self.generation
    requestTask = Task { @MainActor [weak self] in
      // Coalesce touch events without ever queuing multiple image decoders.
      do { try await Task.sleep(for: .milliseconds(warming ? 0 : 35)) } catch { return }
      guard let self, self.generation == generation else { return }
      let target = self.requestedTime
      let timeout = Task { @MainActor in
        do { try await Task.sleep(for: .milliseconds(warming ? 1000 : 1500)) } catch { return }
        generator.cancelAllCGImageGeneration()
      }
      let result = try? await generator.image(at: CMTime(seconds: target, preferredTimescale: 600))
      timeout.cancel()
      guard self.generation == generation, !Task.isCancelled else { return }
      self.requestTask = nil
      self.warmRequest = false
      if let result {
        self.store(UIImage(cgImage: result.image), at: result.actualTime.seconds)
      } else if warming {
        self.warmFailures += 1
      } else if let fallback = self.fallbackGenerator {
        // Some HLS streams have no usable image/I-frame track. Fall back once
        // to on-demand extraction from the original, only while playback is paused.
        self.generator = fallback
        self.fallbackGenerator = nil
        self.allowsWarmup = false
        self.requestFrame(warming: false)
        return
      }
      if !warming, self.isActive {
        let frame = self.nearest(to: self.requestedTime)
        self.image = frame?.image
        self.imageTime = frame?.time ?? self.requestedTime
        // Finish the newest request, never an obsolete queue of finger positions.
        if abs(self.requestedTime - target) > 0.5 { self.requestFrame(warming: false) }
      }
    }
  }
}

private enum PreviewFrameRenderer {
  static let context = CIContext(options: [.cacheIntermediates: false])
}

struct TimelinePreviewOverlay: View {
  let previews: TimelinePreviewController
  let layout: PlayerVideoLayout

  var body: some View {
    if previews.isActive, let image = previews.image {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: layout == .fit ? .fit : .fill)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipped()
        .overlay(alignment: .topLeading) {
          let seconds = max(Int(previews.imageTime), 0)
          Text(String(format: "预览 %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
            .font(.caption.monospacedDigit())
            .padding(6)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(12)
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    } else if previews.isActive {
      VStack {
        Spacer()
        Text("正在读取预览…")
          .font(.caption)
          .padding(8)
          .background(.black.opacity(0.55), in: Capsule())
        Spacer().frame(height: 100)
      }
      .allowsHitTesting(false)
    }
  }
}

final class PlayerLayerView: UIView {
  override static var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer {
    layer as! AVPlayerLayer
  }
}

struct SystemPlayerView: UIViewRepresentable {
  let player: AVPlayer
  let presentationController: SystemPlayerPresentationController
  var videoLayout: PlayerVideoLayout = .fit

  func makeCoordinator() -> Coordinator {
    Coordinator(presentationController: presentationController)
  }

  func makeUIView(context: Context) -> PlayerLayerView {
    let view = PlayerLayerView()
    view.backgroundColor = .black
    view.playerLayer.player = player
    view.playerLayer.videoGravity = videoLayout.gravity
    context.coordinator.presentationController.attach(playerLayer: view.playerLayer)
    return view
  }

  func updateUIView(_ uiView: PlayerLayerView, context: Context) {
    if uiView.playerLayer.player !== player {
      uiView.playerLayer.player = player
    }
    if uiView.playerLayer.videoGravity != videoLayout.gravity {
      uiView.playerLayer.videoGravity = videoLayout.gravity
    }
    context.coordinator.presentationController.attach(playerLayer: uiView.playerLayer)
  }

  static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
    coordinator.presentationController.detach(playerLayer: uiView.playerLayer)
    uiView.playerLayer.player = nil
  }

  final class Coordinator {
    let presentationController: SystemPlayerPresentationController

    init(presentationController: SystemPlayerPresentationController) {
      self.presentationController = presentationController
    }
  }
}

/// Lightweight live scrub preview that mirrors the exact frame currently
/// visible in the primary AVPlayerLayer. Updates happen inside UIKit via a
/// display link so SwiftUI does not re-render the whole player at 30 fps.
struct SystemPlayerScrubPreviewView: UIViewRepresentable {
  let presentationController: SystemPlayerPresentationController

  func makeCoordinator() -> Coordinator {
    Coordinator(presentationController: presentationController)
  }

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView()
    view.backgroundColor = .black
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    context.coordinator.attach(view)
    return view
  }

  func updateUIView(_ uiView: UIImageView, context: Context) {
    context.coordinator.attach(uiView)
  }

  static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator: NSObject {
    private let presentationController: SystemPlayerPresentationController
    private weak var imageView: UIImageView?
    private var displayLink: CADisplayLink?
    private var lastCaptureTimestamp: CFTimeInterval = 0

    init(presentationController: SystemPlayerPresentationController) {
      self.presentationController = presentationController
    }

    func attach(_ imageView: UIImageView) {
      self.imageView = imageView
      if displayLink == nil {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
          link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        } else {
          link.preferredFramesPerSecond = 30
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
      }
      captureFrame()
    }

    func stop() {
      displayLink?.invalidate()
      displayLink = nil
      imageView = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
      // The preferred frame rate already caps this at ~30 fps; the timestamp
      // check avoids duplicate work on ProMotion devices during mode changes.
      guard link.timestamp - lastCaptureTimestamp >= (1.0 / 34.0) else { return }
      lastCaptureTimestamp = link.timestamp
      captureFrame()
    }

    private func captureFrame() {
      guard let image = presentationController.displayedFrameImage(maximumDimension: 420) else { return }
      imageView?.image = image
    }
  }
}

struct AirPlayRoutePickerButton: UIViewRepresentable {
  var onPresentationChanged: (Bool) -> Void = { _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(onPresentationChanged: onPresentationChanged)
  }

  func makeUIView(context: Context) -> AVRoutePickerView {
    let view = AVRoutePickerView()
    view.delegate = context.coordinator
    view.prioritizesVideoDevices = true
    view.tintColor = .white
    view.activeTintColor = UIColor(CinevaTheme.accent)
    view.backgroundColor = .clear
    return view
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    context.coordinator.onPresentationChanged = onPresentationChanged
    uiView.tintColor = .white
    uiView.activeTintColor = UIColor(CinevaTheme.accent)
  }

  final class Coordinator: NSObject, AVRoutePickerViewDelegate {
    var onPresentationChanged: (Bool) -> Void

    init(onPresentationChanged: @escaping (Bool) -> Void) {
      self.onPresentationChanged = onPresentationChanged
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
      onPresentationChanged(true)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
      onPresentationChanged(false)
    }
  }
}
