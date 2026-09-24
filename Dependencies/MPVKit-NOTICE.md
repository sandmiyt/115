# mpv integration

Cineva links the LGPL `MPVKit` product, **not** `MPVKit-GPL`.

- MPVKit source/build scripts: https://github.com/mpvkit/MPVKit/tree/f82e06d4f5ef4fc4aa9faba3782a462dbbef870c
- Revision pinned in Gallery115.xcodeproj; upstream Package.swift pins binary URLs and SHA-256 checksums.
- This upstream revision identifies mpv 0.41.0 and FFmpeg 9.0.1. Its build scripts, patches, component revisions and component licenses are available at that revision.
- MPVKit LGPL v3 text is shipped as `Gallery115/Resources/MPVKit-LICENSE.txt` and displayed in Settings > About. Component copyright and license notices remain available with the linked upstream sources. The license incorporates GPL v3: https://www.gnu.org/licenses/gpl-3.0.html
- Integration code: `Gallery115/Player/MPVPlayerView.swift`. The CAMetalLayer 1x1-resize workaround follows the MPVKit iOS Metal example; the player lifecycle, queue, controls and cache integration are Cineva changes (2026-09-24). The integration source is provided in this repository for modification and rebuilding.
- HTTPS uses certificate verification with Mozilla roots distributed by certifi at revision `9d0a8f1f3a0d6b2e38d5773db7afe1a37e4527b6`: https://github.com/certifi/python-certifi/tree/9d0a8f1f3a0d6b2e38d5773db7afe1a37e4527b6 . The bundle and its MPL 2.0 notice are shipped in Resources.

## Rebuilding with a modified library

Use Xcode on macOS, run `pod install`, open Gallery115.xcworkspace and replace the pinned MPVKit Swift Package reference with a local modified checkout. MPVKit's README documents building its frameworks with `make build platform=ios` and selecting the resulting local xcframeworks in Package.swift. Build Gallery115 for iPhone with signing disabled (the existing IPA workflow contains the full xcodebuild command), or sign the rebuilt app with your own identity. Cineva imposes no library integrity check or restriction on replacing/relinking this dependency for debugging modifications.

## Behavior and limits

mpv owns demuxing, VideoToolbox decoding and packet prefetch. A bounded memory cache preserves forward packets and 32 MiB of previous packets; disk cache is off because mpv's append-only disk cache does not impose a bounded file-size limit. The UI shows native `demuxer-cache-state/seekable-ranges`. Original bytes and authentication headers are unchanged, and cache misses still require network access and decoding. Native AVPlayer remains selectable for its system HDR/PiP/AirPlay path. This build does not claim device-tested HDR parity, instant arbitrary seeks, or measured superiority over other apps.
