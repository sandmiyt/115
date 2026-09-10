import Foundation
import XCTest
@testable import CinevaCacheValidation

@MainActor
final class LibraryStoreTests: XCTestCase {
  private func video(_ path: String, size: Int64 = 100, version: String = "version-a") -> CloudItem {
    CloudItem(id: path, parentID: "/", name: "movie.mp4", isDirectory: false,
      pickCode: path, sha1: version, size: size, fileExtension: "mp4", isVideo: true,
      duration: 0, thumbnailURLString: nil, modifiedAt: Date(timeIntervalSince1970: 1000))
  }

  func testLegacyFavoritesRelocateAndPersistAfterRootChange() throws {
    let suite = "LibraryStoreTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let old = video("/115/old/root/movie.mp4")
    let current = video("/115/movie.mp4")
    defaults.set(try JSONEncoder().encode([old]), forKey: "gallery115.favorites.v1")
    let store = LibraryStore(defaults: defaults)
    store.reconcileFavorites(with: [current])
    XCTAssertTrue(store.isFavorite(current))
    XCTAssertFalse(store.isFavorite(old))
    XCTAssertEqual(store.favorites.map(\.id), [current.id])
    XCTAssertEqual(LibraryStore(defaults: defaults).favorites.map(\.id), [current.id])
  }

  func testBatchFavoritesAreIdempotentAndOnlyRemoveSelectedItems() throws {
    let suite = "LibraryStoreTests-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LibraryStore(defaults: defaults)
    let first = video("/first.mp4")
    let second = video("/second.mp4")
    store.setFavorites([first, second, first], enabled: true)
    store.setFavorites([first], enabled: true)
    XCTAssertEqual(store.favorites.count, 2)
    store.setFavorites([first], enabled: false)
    XCTAssertEqual(store.favorites.map(\.id), [second.id])
    XCTAssertTrue(store.isFavorite(second))
    XCTAssertFalse(store.isFavorite(first))
    XCTAssertEqual(LibraryStore(defaults: defaults).favorites.map(\.id), [second.id])
  }

  func testAmbiguousOrUnversionedFilesDoNotStealFavorites() {
    let old = video("/old/movie.mp4")
    let one = video("/one/movie.mp4")
    let two = video("/two/movie.mp4")
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([old], with: [one, two]), [old])
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([old], with: [video("/new/movie.mp4", size: 101)]), [old])
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([old], with: [video("/new/movie.mp4", version: "other")]), [old])
    let noVersion = video("/old/movie.mp4", version: "")
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([noVersion], with: [video("/new/movie.mp4", version: "")]), [noVersion])
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([old], with: []), [old])
  }

  func testReconciliationKeepsExactPathsAndDeduplicatesRelocatedEntries() {
    let old = video("/old/movie.mp4")
    let current = video("/current/movie.mp4")
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([old], with: [old, current]), [old])
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([old, current], with: [current]), [current])
    let official = video("115-numeric-id")
    XCTAssertEqual(FavoriteRelocationPolicy.reconciled([official], with: [current]), [official])
  }
}
