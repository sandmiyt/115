import Foundation
import XCTest
@testable import CinevaCacheValidation

final class ContinuousGridTests: XCTestCase {
  func testIntermediateCoverageMatchesExhaustiveGeometry() {
    for count in [0, 1, 7, 100, 10_000] {
      for compact in [true, false] {
        for width in [320.0, 430, 844] {
          for step in 0...80 {
            let geometry = PhotoGridGeometry(width: width, position: Double(step) / 20,
              compact: compact, top: 293, captionHeight: 53, count: count)
            for y in [0, geometry.bottom * 0.47, max(0, geometry.bottom - 700)] {
              let rect = CGRect(x: 0, y: y, width: width, height: 700)
              let actual = geometry.candidates(in: rect).filter { geometry.frame($0).intersects(rect) }
              let oracle = (0..<count).filter { geometry.frame($0).intersects(rect) }
              XCTAssertEqual(actual, oracle, "count=\(count) position=\(geometry.position) y=\(y)")
              XCTAssertLessThan(geometry.candidates(in: rect).count, 300)
            }
          }
        }
      }
    }
  }

  func testThirtyRapidCrossDensityReversalsAndSettlingTakeovers() {
    let widths = PhotoGridGeometry(width: 430, position: 4, compact: true,
      top: 0, captionHeight: 0, count: 10_000).widths
    var state = PhotoGridZoomState()
    for _ in 0..<30 {
      state.position = 4
      state.begin(widths: widths)
      state.track(scale: widths[0] / widths[4], speed: 4, widths: widths)
      XCTAssertEqual(state.position, 0, accuracy: 0.0001)
      XCTAssertEqual(state.phase, .tracking)
      state.track(scale: 1, speed: -4, widths: widths)
      XCTAssertEqual(state.position, 4, accuracy: 0.0001)
      state.track(scale: 2.3, speed: 0.2, widths: widths)
      state.end()
      _ = state.step(seconds: 1 / 120, reduceMotion: false)
      let presented = state.position, generation = state.generation
      state.begin(widths: widths)
      XCTAssertEqual(state.generation, generation + 1)
      state.track(scale: 1, speed: 0, widths: widths)
      XCTAssertEqual(state.position, presented, accuracy: 0.0001)
      state.track(scale: 0.7, speed: -1, widths: widths)
      XCTAssertGreaterThan(state.position, presented)
      state.end()
      for _ in 0..<240 { _ = state.step(seconds: 1 / 120, reduceMotion: false) }
      XCTAssertEqual(state.phase, .idle)
      XCTAssertEqual(state.position, state.position.rounded())
    }
  }

  func testCancellationAndReduceMotionConvergeAtBothRefreshRates() {
    for rate in [60.0, 120] {
      for reduced in [false, true] {
        var state = PhotoGridZoomState()
        state.position = 2.35
        state.velocity = -5
        state.end(cancelled: true)
        for _ in 0..<Int(rate * 2) { _ = state.step(seconds: 1 / rate, reduceMotion: reduced) }
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.position, 2)
      }
    }
  }

  func testSizeBucketsAreFiniteAndMonotonic() {
    XCTAssertEqual(Set((1...4000).map { ArtworkSizeTier.pixels(for: $0) }), [320, 640, 960])
  }
}
