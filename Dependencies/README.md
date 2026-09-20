# MobileVLCKit build dependency

The app requires MobileVLCKit 3.7.3 for formats AVPlayer cannot play. The version
is pinned for both local CocoaPods installs and GitHub Actions.

The official VideoLAN binary server repeatedly timed out on GitHub's hosted
macOS runner. CI sets `CINEVA_VLC_MIRROR=github` to select the local podspec and
download Showbie's repackaged 3.7.3 XCFramework release from GitHub:

- Package: https://github.com/showbie/MobileVLCKit-SPM/releases/tag/3.7.3
- Package manifest: https://github.com/showbie/MobileVLCKit-SPM/blob/3.7.3/Package.swift
- ZIP SHA-256: `0346e458e119d57d4768d4096e2f7b4f77b7a0df4e21d0e728856f309cc6e8ab`

The checksum matches the release asset metadata and the tagged package manifest.
This is a third-party ZIP repackaging, not VideoLAN's original `.tar.xz`; the
archive checksums are different. CocoaPods verifies the pinned ZIP checksum
before installation. The podspec keeps the official 3.7.3 framework/linker
settings and includes the license text from
https://github.com/videolan/vlckit/blob/3.7.3/COPYING because the mirror ZIP only
contains the XCFramework. CI caches verified CocoaPods downloads, with the cache
key tied to the Podfile and podspec contents.

Local `pod install` continues to use the official source. If it is unavailable,
run `CINEVA_VLC_MIRROR=github pod install`, or prefix `./build_unsigned_ipa.sh`
with the same environment variable. No playback engine or codec is removed to
work around a download failure.
