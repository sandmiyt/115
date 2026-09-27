import UIKit
import XCTest
@testable import CinevaCacheValidation

@MainActor
final class PhotoGridLayoutTests: XCTestCase {
  func testCachedCellsSurviveThirtyZoomRoundsWithFoldersAndFavorites() {
    for folders in [0, 6] {
      let data = CachedGridData(folders: folders)
      let layout = PhotoGridLayout(mediaColumns: 6, folderColumns: 2, compact: true)
      let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), collectionViewLayout: layout)
      view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
      view.dataSource = data
      let window = UIWindow(frame: view.frame)
      let controller = UIViewController()
      window.rootViewController = controller
      controller.view.addSubview(view)
      window.makeKeyAndVisible()
      view.reloadData(); view.layoutIfNeeded()
      for round in 0..<30 {
        let anchor = [0, 5_000, 9_999][round % 3]
        // Cross multiple levels and reverse without creating another layout.
        for position in [4.0, 3.1, 1.6, 0.1, 2.8, 1.2, 3.9, 4.0] {
          layout.position = position
          layout.invalidateLayout()
          let y = layout.geometry.frame(anchor).midY - view.bounds.height / 2
          view.contentOffset.y = min(max(0, y), max(0, layout.collectionViewContentSize.height - view.bounds.height))
          view.layoutIfNeeded()
          let expected = Set((layout.layoutAttributesForElements(in: view.bounds) ?? [])
            .filter { $0.frame.intersects(view.bounds.insetBy(dx: 0.5, dy: 0.5)) }.map(\.indexPath))
          XCTAssertTrue(expected.isSubset(of: Set(view.indexPathsForVisibleItems)), "missing real cell, round=\(round), position=\(position)")
          for cell in view.visibleCells {
            XCTAssertNotNil((cell.backgroundView as? UIImageView)?.image)
            if let path = view.indexPath(for: cell) { XCTAssertEqual(cell.accessibilityIdentifier, "\(path.section):\(path.item)") }
          }
          XCTAssertTrue(view.collectionViewLayout === layout)
        }
      }
      // Rotation and a short refreshed directory reuse the same layout instance.
      view.frame.size = CGSize(width: 844, height: 390)
      data.mediaCount = 7
      view.reloadData(); layout.invalidateLayout(); view.contentOffset = .zero; view.layoutIfNeeded()
      XCTAssertFalse(view.visibleCells.isEmpty)
      window.isHidden = true
    }
  }
}

@MainActor
private final class CachedGridData: NSObject, UICollectionViewDataSource {
  let folders: Int
  var mediaCount = 10_000
  let image: UIImage
  init(folders: Int) {
    self.folders = folders
    image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
      UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
  }
  func numberOfSections(in collectionView: UICollectionView) -> Int { 3 }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    section == 0 ? folders : (section == 1 ? mediaCount : 1)
  }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: path)
    cell.backgroundView = UIImageView(image: image)
    cell.accessibilityIdentifier = "\(path.section):\(path.item)"
    return cell
  }
}
