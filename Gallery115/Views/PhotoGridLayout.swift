import UIKit

final class PhotoGridLayout: UICollectionViewLayout {
  var position: Double
  var folderColumns: Int
  var compact: Bool
  var mediaColumns: Int { MediaGridZoomPolicy.levels[Int(min(max(position.rounded(), 0), 4))] }
  init(mediaColumns: Int, folderColumns: Int, compact: Bool) {
    self.position = Double(MediaGridZoomPolicy.levels.firstIndex(of: mediaColumns) ?? 2)
    self.folderColumns = max(1, folderColumns); self.compact = compact
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("Programmatic layout only") }
  private var width: CGFloat { max(collectionView?.bounds.width ?? 1, 1) }
  private func count(_ section: Int) -> Int {
    guard let collectionView, collectionView.numberOfSections > section else { return 0 }
    return collectionView.numberOfItems(inSection: section)
  }
  private var folderWidth: CGFloat { max(1, (width - 20 - CGFloat(folderColumns - 1) * 9) / CGFloat(folderColumns)) }
  private var folderHeight: CGFloat {
    folderWidth * 9 / 16 + UIFont.preferredFont(forTextStyle: .subheadline).lineHeight * 2
      + UIFont.preferredFont(forTextStyle: .caption2).lineHeight + 16
  }
  private var mediaTop: CGFloat {
    count(0) == 0 ? 2 : 13 + CGFloat((count(0) + folderColumns - 1) / folderColumns) * (folderHeight + 11)
  }
  var geometry: PhotoGridGeometry {
    PhotoGridGeometry(width: Double(width), position: position, compact: compact, top: Double(mediaTop),
      captionHeight: Double(UIFont.preferredFont(forTextStyle: .caption1).lineHeight * 2 + 7), count: count(1))
  }
  var mediaRegion: CGRect { CGRect(x: 0, y: mediaTop, width: width, height: max(0, geometry.bottom - Double(mediaTop))) }
  override var collectionViewContentSize: CGSize { CGSize(width: width, height: geometry.bottom + 88) }
  override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard path.item >= 0, path.item < count(path.section) else { return nil }
    let attr = UICollectionViewLayoutAttributes(forCellWith: path)
    switch path.section {
    case 0:
      attr.frame = CGRect(x: 10 + CGFloat(path.item % folderColumns) * (folderWidth + 9),
        y: 10 + CGFloat(path.item / folderColumns) * (folderHeight + 11), width: folderWidth, height: folderHeight)
    case 1: attr.frame = geometry.frame(path.item)
    case 2: attr.frame = CGRect(x: 0, y: geometry.bottom, width: Double(width), height: 88)
    default: return nil
    }
    return attr
  }
  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    let geometry = geometry
    var attributes: [UICollectionViewLayoutAttributes] = []
    let first = max(0, Int(floor((rect.minY - 10) / (folderHeight + 11)))) * folderColumns
    let last = min(count(0), max(0, Int(ceil((rect.maxY - 10) / (folderHeight + 11))) + 1) * folderColumns)
    if first < last {
      for index in first..<last {
        if let attr = layoutAttributesForItem(at: IndexPath(item: index, section: 0)), attr.frame.intersects(rect) { attributes.append(attr) }
      }
    }
    for index in geometry.candidates(in: rect) {
      let frame = geometry.frame(index)
      if frame.intersects(rect) {
        let attr = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 1))
        attr.frame = frame; attributes.append(attr)
      }
    }
    if let footer = layoutAttributesForItem(at: IndexPath(item: 0, section: 2)), footer.frame.intersects(rect) { attributes.append(footer) }
    return attributes
  }
  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != collectionView?.bounds.size }
}

