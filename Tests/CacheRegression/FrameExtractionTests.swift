import AVFoundation
import UIKit
import XCTest
@testable import CinevaCacheValidation

final class FrameExtractionTests: XCTestCase {
  func testNearStartThumbnailFromLocalVideo() async throws {
    // A fixed 1-second H.264 fixture tests extraction without first depending
    // on a simulator's encoder becoming ready on a busy shared CI host.
    let url = try XCTUnwrap(Bundle.module.url(forResource: "near-start", withExtension: "mp4"))
    let source = VideoSource(id: "fixture", title: "fixture", definition: 100,
                             url: url, kind: .original, headers: [:])
    let image = await ThumbnailService.frameThumbnail(source: source)
    XCTAssertNotNil(image)
    XCTAssertEqual(image?.size, CGSize(width: 64, height: 64))
  }
}
