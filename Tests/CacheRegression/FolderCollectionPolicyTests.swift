import Foundation
import XCTest
@testable import CinevaCacheValidation

final class FolderCollectionPolicyTests: XCTestCase {
  func testIncrementalPageNeverMovesExistingViewportItems() {
    let current = [item("b", date: 200), item("d", date: 100)]
    let next = [item("a", date: 400), item("c", date: 300)]

    let result = CloudItemCollectionPolicy.appendingPage(next, to: current, by: .updated)

    XCTAssertEqual(result.map(\.id), ["b", "d", "a", "c"])
  }

  func testIncrementalPageDeduplicatesOverlappingOffsets() {
    let current = [item("a", date: 300), item("b", date: 200)]
    let next = [item("b", date: 200), item("c", date: 100), item("c", date: 100)]

    let result = CloudItemCollectionPolicy.appendingPage(next, to: current, by: .updated)

    XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
  }

  func testSilentFirstPageRefreshUpdatesInPlaceWithoutTruncatingLoadedPages() {
    let current = [item("a", sha1: "old"), item("b"), item("c")]
    let firstPage = [item("new", date: 500), item("a", sha1: "fresh")]

    let result = CloudItemCollectionPolicy.mergingFirstPage(firstPage, into: current, by: .updated)

    XCTAssertEqual(result.map(\.id), ["a", "b", "c", "new"])
    XCTAssertEqual(result.first?.sha1, "fresh")
  }

  func testEqualPrimaryValuesHaveDeterministicTieBreakers() {
    let values = [item("2", name: "Same", date: 100), item("1", name: "Same", date: 100)]

    XCTAssertEqual(
      CloudItemCollectionPolicy.ordered(values, by: .updated).map(\.id),
      ["1", "2"]
    )
  }

  private func item(
    _ id: String,
    name: String? = nil,
    sha1: String = "etag",
    date: Double = 100
  ) -> CloudItem {
    CloudItem(
      id: id,
      parentID: "/115",
      name: name ?? "\(id).mp4",
      isDirectory: false,
      pickCode: id,
      sha1: sha1,
      size: 1_024,
      fileExtension: "mp4",
      isVideo: true,
      duration: 0,
      thumbnailURLString: nil,
      modifiedAt: Date(timeIntervalSince1970: date)
    )
  }
}
