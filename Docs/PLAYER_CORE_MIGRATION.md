# PlayerCore migration: Phase 1 delivery

Baseline: commit `885e6bd`, 2.2.9 (41), restored from the original 2.2.9 (33) commit `13ade36`, with the explicit 1080P preference removed. Phase 1 is 2.2.9 (42). This is an interface migration, **not a delivered FFmpeg decoder** and not a claim of better playback speed.

## 1. Current playback chain and audit

1. `Views/FolderView.swift`, `FavoritesView.swift`, `RecentView.swift` present `PlayerScreen` after selecting a video.
2. `Views/PlayerScreen.swift:prepareCurrentItem` suspends thumbnail network work and background artwork discovery, creates `PlayerModel`, and passes persisted engine/quality/rate settings.
3. `Services/APIClient.swift:initialVideoSources` resolves the selected provider. For 115 originals it requests the original first and defers transcode discovery. Other paths use the existing source list.
4. `Services/Cloud115Provider.swift` obtains originals using `/open/ufile/downurl` and transcodes using `/open/video/play`; `Cloud115AuthManager` handles existing authorization/refresh. `VideoSource` carries URL and headers. Current 115 source headers contain User-Agent. OAuth API tokens must not automatically be forwarded to a CDN host by a future AVIO adapter.
5. `Services/WebDAVProvider.swift:videoSources` supplies the original URL, User-Agent and configured Basic Authorization. No provider/authentication code changes in Phase 1.
6. `Player/PlayerModel.swift` passes source headers into `AVURLAsset`, creates `AVPlayerItem`, and starts `AVPlayer`. `Player/SystemPlayerView.swift` presents `AVPlayerLayer` and native PiP. System framework handles media IO, decoding and synchronization.
7. An unsupported original container, explicit VLC preference, or sustained system failure can route to `Player/VLCPlayerView.swift`. Its pinned MobileVLCKit 3.7.3 owns decoding/output. The adapter forwards User-Agent and Basic credentials; it does not currently forward an arbitrary Cookie/header dictionary. This is a gap to address in the future custom IO path, not a claim of generic header support today.

### Existing features and limitations

| Area | Current implementation / migration constraint |
|---|---|
| Video cache | AVPlayer owns native read-ahead. There is no application-owned media Range/disk cache or proof of cache hits. `loadedTimeRanges` measures time ranges, not cached file bytes. |
| Preview cache | `TimelinePreviewController` in `SystemPlayerView.swift`: coalesced AVAssetImageGenerator requests, at most 32 MiB / 160 preview frames. Preview images are not the video rendering path. |
| VLC buffering | Existing 1800 / 3500 ms network buffer, 4200 ms for disc images. No resident byte-range telemetry exposed by this adapter. |
| Seek | Native main-player seek commits on release with generation guards; VLC coalesces interactive seeks. These existing algorithms are unchanged in Phase 1. |
| History | `LibraryStore` stores resume/history; native path also updates 115 history. The current VLC adapter saves local progress. |
| Embedded tracks | AVPlayer media selection. VLC track selection has not been exposed in this app; new optional track capability does not fabricate it. |
| External subtitles | Existing SRT/WebVTT and text extraction from ASS/SSA. ASS typography/position is stripped; no complete libass or PGS implementation. Overlay stays separate from video. |
| Chapters / metadata | Native asset metadata + sidecar chapters; no FFmpeg metadata analyzer yet. |
| HDR / Dolby | Existing native AVPlayer HDR metadata path. No new guarantee of Dolby Vision profiles, Atmos passthrough or actual hardware decoder identity. |
| UI / gestures | `PlayerScreen`: same gestures, pinch, orientation, full screen, queue, next episode, speed and favorites. |
| Background | Existing playback AVAudioSession, interruption handling, Info.plist audio background mode. |
| Remote control | Existing `PlayerRemoteSession` in PlayerScreen: Now Playing and remote commands. |
| PiP / AirPlay | Existing system presentation controller / AVRoutePicker; VLC still has the prior PiP limitation. Custom decoded-sample PiP and native handoff are not yet implemented. |

## 2. Old-to-new mapping and implemented architecture

```text
PlayerScreen controls / timeline / track menu / media diagnostics
                      |
                 PlayerEngine
           state + statistics + commands
                 /          \
        PlayerModel       VLCPlaybackController
       AVPlayer adapter     VLCKit adapter
          |                     |
     AVPlayerLayer          VLCKit drawable
```

| Old module | Phase 1 mapping | Later phase |
|---|---|---|
| Protocol embedded in PlayerModel | `PlayerCore/PlayerEngine.swift`, with the old API aliases retained | FFmpeg backend implements the same control boundary |
| UI branches for each command/scrub | `activeEngine` routes commands to selected backend | Backend lifecycle / source preparation can subsequently move behind a controller |
| UI combines per-engine booleans | Each adapter exposes `PlayerState` | FFmpeg publishes state from its own queue/decoder events |
| AVMediaSelectionOption exposed in menu | `PlayerTrackSelecting` + value-only `PlayerTrack` | FFmpeg stream IDs and real VLC track support |
| Native stats accidentally reused after VLC switch | `PlayerStatistics` supplied by active engine | Native FFmpeg decoder, queue, IO and sync telemetry |
| Chapter / subtitle value types inside AV model | `PlayerCore/PlayerTypes.swift` | Independent subtitle engine and renderer |

The public Core API imports Foundation/CoreGraphics only. It exposes no FFmpeg, AVFoundation or VLCKit objects. Native rendering/PiP bridges and existing source orchestration remain explicit in their existing files; this phase does not disguise AVPlayer as FFmpeg. State is translated from the existing backends during this phase; this is not yet the future packet-queue state machine.

## 3. Changed files

- `Gallery115/PlayerCore/PlayerEngine.swift`: real transport, scrub and optional track capability used by the shipping UI.
- `Gallery115/PlayerCore/PlayerTypes.swift`: state, backend identity, track, chapter, subtitle and nullable statistics types.
- `Gallery115/Player/PlayerModel.swift`: native adapter conformance and observed statistics/track projection; decoding/network policies retained.
- `Gallery115/Player/VLCPlayerView.swift`: VLC state/statistics adapter; existing playback/configuration retained.
- `Gallery115/Views/PlayerScreen.swift`: unified command/state reads, backend-correct track dispatch and media information.
- `Gallery115.xcodeproj/project.pbxproj`: adds the two actual sources to the shipping target, build 42.
- This document: audit, phase status and device acceptance checklist.

## 4. FFmpeg integration and hardware codec status

**Phase 2 has not started.** No new FFmpeg dependency, C bridge or linker flags are installed in this build. MobileVLCKit's internal dependencies are not claimed as FFmpeg 8.0.2 integration.

FFmpeg 8.0.2 exists in the [official release archive](https://ffmpeg.org/releases/). The planned dependency must be pinned to that source/version, reproducibly built with VideoToolbox and audited flags, and exclude GPL/nonfree components. Source, build configuration and binary provenance must accompany distribution. See [FFmpeg's license guidance](https://ffmpeg.org/legal.html). Do not reuse the removed mpv/MoltenVK package for this migration.

**Newly verified hardware codecs: none.** Existing AVPlayer/VLC decoding remains active; actual hardware/software selection is not exposed by these adapters and displays “当前内核未提供”. H.264, HEVC Main10, VP9 and AV1 hardware capability must later be checked per device/profile/pixel format, with real software fallback and decode evidence. HDR/Dolby indicators must not stand in for hardware-decoder evidence.

## 5. 115 Range/cache design status

Phase 1 preserves URL/credential delivery to the current engines. No AVIOContext, Range retry/reconnect algorithm, shared byte cache or disk cache has been implemented. Downloaded byte totals are kept separate from resident cache bytes; unavailable cache bytes display “未提供”, never the download total.

Phase 7/8 acceptance requires 206/Content-Range validation; explicit handling of 200/416; seek-generation cancellation; bounded memory/disk budgets; source-identity/validator checks; same-range request coalescing; and no credential leakage across redirects or logs. Expired 115 URLs must refresh through the existing authenticated resolver. HLS playlists need a separate strategy rather than being treated as a single flat Range file.

## 6. Remaining capabilities / phase gates

| Phase | Status |
|---|---|
| 1: shared engine interface | Implemented; compilation/device status below |
| 2: FFmpeg 8.0.2 dependency | Not started; requires Phase 1 device gate |
| 3: demux / software decoding | Not implemented |
| 4: VideoToolbox + software fallback | Not implemented |
| 5: CVPixelBuffer / native or Metal rendering | Not implemented for FFmpeg |
| 6: audio output, resample/time stretch, audio-led AV sync | Not implemented for FFmpeg |
| 7: custom 115 AVIO / HTTP Range | Not implemented |
| 8: bounded packet/frame queues, cache and seek generations | Not implemented |
| 9: libass, styled ASS/SSA, PGS | Not implemented |
| 10: HDR metadata, Dolby/native strategy, custom PiP/AirPlay | Not implemented |
| 11: real-device performance acceptance | Not performed |

No promise of millisecond scrubbing, large-file instant startup, zero-copy, low temperature or reduced stalls is made by this interface-only phase.

## 7. Validation evidence

- Original rollback build (41): GitHub run `36213589648`, successful compilation and IPA packaging.
- Existing `Tests/preflight.py`: source checks passed; 2 known parser limitations require Xcode. The script does not execute its 57 prepared XCTest cases.
- Phase 1 build (42): see the GitHub commit's `Build unsigned IPA` run; completion is reported in the delivery message. Compilation/packaging is not a device playback test.
- Local simulator discovery: `spawn xcrun ENOENT` on this Windows host. No simulator launch or iPhone playback verification performed by the agent.
- No new regression job, regression executable, or test artifact added. The existing IPA workflow remains unchanged.

The user's specification requires app launch and no evident old-feature regressions **before the next phase**. The user confirmed their iPhone is available for this validation. The migration stops at that runtime gate until its results arrive, rather than installing another untested default engine.

## 8. iPhone acceptance checklist before Phase 2

Use the same long 115 original and the same network for build 41 and build 42. Report engine, file container, time to first frame and whether a crash occurred; do not send signed URLs or account tokens.

- [ ] App opens; 115 account/library, folders, search, thumbnails and favorites remain available; 1080P preference stays removed.
- [ ] AVPlayer original starts; pause/resume, volume, 0.5x/1x/2x and replay work.
- [ ] Ten forward/backward scrubs, including a cached and an uncached position; no stale picture or audio continuation after pause.
- [ ] Close/reopen resumes the previous position; next episode and automatic next/replay still work.
- [ ] Switch native audio tracks and subtitles; external SRT/ASS text overlay still works.
- [ ] VLC original opens and seeks; its info page says VLC and does not claim AVPlayer codec/HDR or cache bytes.
- [ ] Pinch, horizontal/vertical gestures, portrait/landscape and full screen work.
- [ ] Native PiP, background audio, lock-screen commands and AirPlay with available receiver work.
- [ ] Play the long original for at least 10 minutes, recording stalls; this phase is expected to retain baseline performance, not fix it.

Later performance phases additionally require representative 4K HEVC Main10, multi-audio/subtitle MKV, high-frame-rate/VFR, HDR10/HLG/Dolby samples and a multi-GB 115 file, plus thermal/memory/network/seek measurements on the user's actual device.
