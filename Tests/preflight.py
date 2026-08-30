"""Source-only preflight. This is NOT an Xcode build or an iOS runtime test."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".validation-tools"))
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))
failures = []

def check(ok, label):
    print(f"{'PASS' if ok else 'FAIL'} {label}")
    if not ok:
        failures.append(label)

sources = [
    "Gallery115/Services/ArtworkDiskStore.swift", "Gallery115/Services/ThumbnailService.swift",
    "Gallery115/Views/VideoCard.swift", "Gallery115/Views/PlayerScreen.swift",
    "Gallery115/Views/SettingsView.swift", "Package.swift", "Tests/CacheSupport.swift",
    "Tests/CacheRegression/ArtworkCacheTests.swift",
    "Tests/CacheRegression/FrameExtractionTests.swift",
    "Tests/CacheRegression/FolderCollectionPolicyTests.swift",
    "Gallery115/Models/CloudItem.swift", "Gallery115/Views/FolderView.swift",
    "Gallery115/Services/APIClient.swift",
    "Gallery115/Services/WebDAVProvider.swift",
]
for name in sources:
    data = (ROOT / name).read_bytes()
    tree = parser.parse(data)
    errors = []
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(node)
        stack.extend(reversed(node.children))
    check(not errors, f"Swift grammar: {name}")
    for node in errors:
        print(f"  {node.type} line {node.start_point.row + 1}: {data[node.start_byte:node.end_byte][:150]!r}")

disk = (ROOT / sources[0]).read_text(encoding="utf-8")
service = (ROOT / sources[1]).read_text(encoding="utf-8")
card = (ROOT / sources[2]).read_text(encoding="utf-8")
player = (ROOT / sources[3]).read_text(encoding="utf-8")
folder = (ROOT / "Gallery115/Views/FolderView.swift").read_text(encoding="utf-8")
cloud_item = (ROOT / "Gallery115/Models/CloudItem.swift").read_text(encoding="utf-8")
project = (ROOT / "Gallery115.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
check(".applicationSupportDirectory" in disk and "isExcludedFromBackup = true" in disk,
      "Persistent, backup-excluded artwork directory")
check("options: .atomic" in disk, "Atomic artwork writes")
check("trimCacheIfNeeded" not in service and "maximumCacheBytes" not in service,
      "No automatic disk eviction")
key = disk.split("var key: String {", 1)[1].split("static func digest", 1)[0]
check(all(field in key for field in ["namespace", "itemID", "size", "modifiedAt"])
      and "legacyKey" not in key, "Stable mount/file identity, no ETag")
check("item.sha1" not in card and "thumbnailURLString" not in card, "Card task identity excludes rotating URLs/ETags")
card_identity = card.split("private var itemThumbnailIdentity", 1)[1].split("@ViewBuilder", 1)[0]
check("item.id" in card_identity and "item.size" in card_identity
      and "modifiedAt" not in card_identity,
      "Directory refresh metadata cannot restart unchanged artwork tasks")
check("cachedImage = nil" not in card
      and "guard let image else { return }" in card,
      "Artwork refresh keeps the existing image until a replacement is ready")
check("activeRequestIdentity == identity" in card,
      "Cancelled recycled artwork cells clear only their own loading state")
check("CloudItemCollectionPolicy.appendingPage" in folder
      and "requestedOffset == nextOffset" in folder,
      "Pagination appends stably and rejects stale page responses")
check("CloudItemCollectionPolicy.mergingFirstPage" in folder
      and "nextOffset = max(nextOffset" in folder,
      "Silent refresh preserves loaded viewport rows and paging progress")
check("await refreshFirstPageSilently()" in folder
      and "Task { await refreshFirstPageSilently() }" not in folder,
      "Silent refresh is cancelled with its folder screen task")
check(folder.count("guard !Task.isCancelled else { return }") >= 7,
      "Cancelled folder/search requests cannot publish stale or offline state")
check("Cached pagination is an expected fast path" in folder
      and 'transientMessage = "已从本地资料库缓存继续加载。"' not in folder,
      "Cache hits do not resize the viewport with a status banner")
check("return lhs.id < rhs.id" in cloud_item,
      "Equal sort values use a deterministic cell identity tie-breaker")
check(all(value in cloud_item for value in ["case .updated:", "case .oldest:",
                                             "case .size:", "case .sizeAscending:"]),
      "Date and size sort directions are implemented")
check("var librarySortDate: Date { createdAt ?? modifiedAt }" in cloud_item,
      "Upload/creation date is preferred with modification-date fallback")
check("sortOrder: collectionSortOrder" in folder
      and "sortMode == .updated" in folder,
      "Folder pagination uses newest-first as the default global order")
check('Label("筛选"' in folder and 'Label("排序"' in folder
      and 'Button {' in folder and 'Image(systemName: "arrow.clockwise")' in folder,
      "Filter and sort share one menu beside a standalone refresh button")
check("load(.duration)" not in service and "load(.isPlayable)" not in service,
      "No thumbnail duration/playability preflight")
check("generator.cancelAllCGImageGeneration()" in service and "asset.cancelLoading()" in service,
      "Cancellation stops AVFoundation reads")
check("activeSlots.count < 2" in service and "playbackOwners.isEmpty" in service,
      "Whole network pipeline is bounded and playback-gated")
check("generation == cacheGeneration" in service and "cacheGeneration = UUID()" in service,
      "Clear invalidates in-flight results")
check("suspendNetwork(for: thumbnailPlaybackOwner)" in player and "resumeNetwork(for: owner)" in player,
      "Player lifecycle acquires/releases thumbnail priority")
check("abs(activeCurrentTime - initialPlaybackTime)" in player, "Auxiliary loads wait for playback progress")
check(project.count("B20260828000000000000001") == 2 and project.count("B20260828000000000000002") == 3,
      "New cache source is referenced by the shipping Xcode target")
protected = ["Gallery115/Player/PlayerModel.swift", "Gallery115/Player/VLCPlayerView.swift",
             "Gallery115/Player/SystemPlayerView.swift",
             "Gallery115/Services/KeychainStore.swift", "Gallery115/Services/LibraryStore.swift"]
unchanged = subprocess.run(["git", "diff", "--exit-code", "--", *protected], cwd=ROOT,
                           capture_output=True).returncode == 0
check(unchanged, "Playback core, credentials and library business logic unchanged")
provider = (ROOT / "Gallery115/Services/WebDAVProvider.swift").read_text(encoding="utf-8")
api_client = (ROOT / "Gallery115/Services/APIClient.swift").read_text(encoding="utf-8")
original_provider = subprocess.check_output(["git", "show", "HEAD:Gallery115/Services/WebDAVProvider.swift"],
                                            cwd=ROOT).decode("utf-8")
def playback_source(text):
    return text.split("  func videoSources(for item:", 1)[1].split("  func localMetadata(for item:", 1)[0]
check(playback_source(provider) == playback_source(original_provider), "WebDAV playback source method is byte-for-byte unchanged")
check("orderedItemCache" in provider and '"|sort|" + sortOrder.rawValue' in provider
      and "CloudItemCollectionPolicy.ordered(allItems, by: sortOrder)" in provider,
      "WebDAV globally sorts once per cached directory/order before paging")
check("<d:creationdate/>" in provider and 'case "creationdate"' in provider,
      "WebDAV requests and parses the standard creation/upload date")
check("sortOrder: CloudItemSortOrder = .updated" in api_client,
      "API pagination defaults to newest-first ordering")
check("if !Task.isCancelled { metadataMisses.insert(item.id) }" in provider,
      "Cancelled artwork discovery cannot poison metadata miss cache")
test_count = sum(len(re.findall(r"func test\w+\(", path.read_text(encoding="utf-8")))
                 for path in (ROOT / "Tests/CacheRegression").glob("*.swift"))
print(f"iOS XCTest cases prepared: {test_count} (not executed by this script)")
print(f"Preflight result: {len(failures)} failure(s); Swift type checking/device validation still required.")
sys.exit(bool(failures))
