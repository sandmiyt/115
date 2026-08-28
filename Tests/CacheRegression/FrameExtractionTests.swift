import AVFoundation
import UIKit
import XCTest
@testable import CinevaCacheValidation

final class FrameExtractionTests: XCTestCase {
  func testNearStartThumbnailFromLocalVideo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CinevaFrameTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("fixture.mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<30 {
      for _ in 0..<1000 {
        if input.isReadyForMoreMediaData { break }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      guard input.isReadyForMoreMediaData else {
        writer.cancelWriting()
        XCTFail("AVAssetWriter did not become ready")
        return
      }
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                      nil, &pixelBuffer)
      XCTAssertEqual(status, kCVReturnSuccess)
      let buffer = try XCTUnwrap(pixelBuffer)
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 180, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    let source = VideoSource(id: "fixture", title: "fixture", definition: 100,
                             url: url, kind: .original, headers: [:])
    let image = await ThumbnailService.frameThumbnail(source: source)
    XCTAssertNotNil(image)
    XCTAssertEqual(image?.size, CGSize(width: 64, height: 64))
  }
}
