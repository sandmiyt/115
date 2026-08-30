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

  func testNewestAndOldestDateOrders() {
    let values = [item("middle", date: 200), item("old", date: 100), item("new", date: 300)]

    XCTAssertEqual(CloudItemCollectionPolicy.ordered(values, by: .updated).map(\.id),
                   ["new", "middle", "old"])
    XCTAssertEqual(CloudItemCollectionPolicy.ordered(values, by: .oldest).map(\.id),
                   ["old", "middle", "new"])
  }

  func testCreationDateTakesPriorityOverOriginalFileModificationDate() {
    let uploadedNow = item("uploaded-now", date: 10, createdDate: 500)
    let oldUpload = item("old-upload", date: 1_000, createdDate: 100)

    XCTAssertEqual(
      CloudItemCollectionPolicy.ordered([oldUpload, uploadedNow], by: .updated).map(\.id),
      ["uploaded-now", "old-upload"]
    )
  }

  func testLargestAndSmallestSizeOrders() {
    let values = [item("middle", size: 200), item("small", size: 100), item("large", size: 300)]

    XCTAssertEqual(CloudItemCollectionPolicy.ordered(values, by: .size).map(\.id),
                   ["large", "middle", "small"])
    XCTAssertEqual(CloudItemCollectionPolicy.ordered(values, by: .sizeAscending).map(\.id),
                   ["small", "middle", "large"])
  }

  private func item(
    _ id: String,
    name: String? = nil,
    sha1: String = "etag",
    size: Int64 = 1_024,
    date: Double = 100,
    createdDate: Double? = nil
  ) -> CloudItem {
    CloudItem(
      id: id,
      parentID: "/115",
      name: name ?? "\(id).mp4",
      isDirectory: false,
      pickCode: id,
      sha1: sha1,
      size: size,
      fileExtension: "mp4",
      isVideo: true,
      duration: 0,
      thumbnailURLString: nil,
      modifiedAt: Date(timeIntervalSince1970: date),
      createdAt: createdDate.map(Date.init(timeIntervalSince1970:))
    )
  }
}
