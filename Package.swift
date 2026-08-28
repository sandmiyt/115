// swift-tools-version: 5.9
import PackageDescription

// Validation only. The shipping app remains Gallery115.xcodeproj + CocoaPods.
// Compile the actual cache implementation, not a copied/reimplemented model.
let package = Package(
  name: "CinevaCacheValidation",
  platforms: [.iOS(.v17)],
  products: [.library(name: "CinevaCacheValidation", targets: ["CinevaCacheValidation"])],
  targets: [
    .target(
      name: "CinevaCacheValidation",
      path: ".",
      exclude: ["Gallery115.xcodeproj", "115褰卞粖_iPhone_v1.0", "cineva-auth-server", ".github",
                "Tests/CacheRegression", "Tests/README.md", "Tests/preflight.py",
                "Gallery115/App", "Gallery115/Player", "Gallery115/Views",
                "Gallery115/Resources", "Gallery115/Info.plist", "Gallery115/Models/PlaybackEntry.swift",
                "Gallery115/Services/APIClient.swift", "Gallery115/Services/Cloud115AuthManager.swift",
                "Gallery115/Services/Cloud115Provider.swift", "Gallery115/Services/CloudProvider.swift",
                "Gallery115/Services/KeychainStore.swift", "Gallery115/Services/LibraryStore.swift",
                "Gallery115/Services/WebDAVProvider.swift", "Podfile", "build_unsigned_ipa.sh"],
      sources: ["Gallery115/Services/ArtworkDiskStore.swift", "Gallery115/Services/ThumbnailService.swift",
                "Gallery115/Models/CloudItem.swift", "Gallery115/Models/VideoSource.swift",
                "Tests/CacheSupport.swift"],
      swiftSettings: [.define("CACHE_VALIDATION")]
    ),
    .testTarget(name: "CacheRegression", dependencies: ["CinevaCacheValidation"], path: "Tests/CacheRegression"),
  ]
)
