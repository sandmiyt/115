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

## Original-video engine routing (2.2.8)

Settings > Playback exposes Automatic, AVPlayer and VLC for original sources.
Automatic keeps native playback until a continuous 15-second interruption or
three interruptions of at least 3 seconds within 60 seconds, then hands the same
URL and current position to VLC once. Network recovery must be enabled; AirPlay,
PiP, intentional pause and active scrubbing suppress the stall handoff. There is
no automatic quality downgrade or AVPlayer/VLC switching loop. VLC receives the
source User-Agent and waits for seekability before restoring the position.

Engine selection was reviewed against the upstream projects:
- https://github.com/videolan/vlckit (the already pinned libvlc integration)
- https://github.com/kingslay/KSPlayer (progress preview and disk precaching are
  listed as paid-version features, not capabilities of its public GPL version)
- https://github.com/mpvkit/MPVKit (upstream cautions about infrequent maintenance
  and patched Metal support)

This is an integration choice, not a measured claim that VLC is universally
faster. Xcode packaging cannot verify a user's authenticated 115 CDN path. Device
checks still needed: the same long original on both engines, sustained stalls,
handoff position/rate/volume, pause/seek/PiP exclusions, and rapid next/back. The
download-speed display samples access-log byte counters and may lag their update;
it is not a packet-level bandwidth measurement. No new regression CI job is added.
