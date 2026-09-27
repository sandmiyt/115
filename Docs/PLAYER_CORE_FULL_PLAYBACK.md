# Cineva full FFmpeg playback — implementation and acceptance record

Baseline: 2.2.9 (49), commit adfb52b. Build 50 introduces a selectable normal
FFmpeg backend. Build 51 adds subtitle decoding/rendering; build 52 completes SUP sidecars, encoding selection, SDR mapping and further lifecycle handling. Existing AVPlayer and
VLC remain available; login, file browsing and library data contracts are unchanged.
This is not a claim that every PlayerCore requirement or device test is complete.

## Actual playback path

`PlayerScreen → FFmpegPlayerEngine → CinevaFFmpegSession` owns:

```
115 / WebDAV HTTP → RangeCoordinator → bounded memory + disk pages
                 → Custom AVIO → FFmpeg demux worker
                    ├ video packets → video worker → CVPixelBuffer → native sample-buffer layer
                    ├ audio packets → audio worker → Swr → PCM → AVAudioPlayerNode → TimePitch → output
                    └ subtitle packets → subtitle worker → libass / PGS bitmap → subtitle overlay
```

Custom AVIO is installed **before** avformat_open_input, so header parsing,
probing, av_read_frame and byte seeks all use it. Demux byte seeks change only
the logical offset. A user seek increments the generation and cancels pending
requests, clears old packet/frame/PCM state, stops scheduled audio, prerolls to
the target, then resumes only if the joint A/V gate permits it. Paused seeking
keeps the clock frozen. AVPlayer is not the renderer inside the FFmpeg engine.

The ordinary screen's playback settings offer FFmpeg / AVPlayer / VLC. FFmpeg
errors trigger one bounded compatibility handoff, preserving position, intent,
rate and volume. Track language/title matching attempts to preserve selections
where the destination actually exposes an equivalent track. No automatic loop
back into FFmpeg is used. Only one audio backend is allowed to run at a time.

## Clock and buffer accounting

Swr normalizes all input channels to stereo interleaved Float32 at 48 kHz using
the complete input channel layout. Samples carry media PTS, valid frame count
and generation. Delay, preroll trimming, timestamp overlap, initial track offset
and EOF resampler drain are handled before bounded PCM enqueue.

The audio clock maps AVAudioPlayerNode's **rendered sample time** to source PTS.
Decoded time, submitted end, rendered time and latency-adjusted audible estimate
are separate diagnostic fields. The audible value is an estimate, not a physical
measurement at the ear. Output-route, engine and TimePitch latency are included.
Rate changes use TimePitch rather than sample-rate substitution.

Video uses PTS and actual AVFrame duration, falling back to guessed FPS only
when duration is invalid. Its native timebase is anchored at explicit boundaries;
while playing it receives a bounded rate correction toward the audio clock,
not a per-frame time jump. No-audio files have a separate video-clock path.

Background audio without PiP suppresses the video stream/decoder and GPU overlay
work while continuing the audio clock and bounded audio queues. Foreground/PiP
restoration coordinates a seek at that clock to rebuild video state. An active or
starting PiP keeps video enabled. Background pumps are throttled separately.
Audio-session playback uses its implicit AirPlay/A2DP routes rather than invalid
playAndRecord-only category options. Actual route continuity remains a device test.

Continuous decoded/submitted/packet intervals are merged **within each track**.
The playable A/V runway is the intersection, never the sum. Startup targets
0.75 seconds. Rebuffer starts at 2 seconds, escalates to at most 4 seconds with
repeated stalls / current I/O latency, and scales with playback rate. EOF tails
and bounded queue saturation have escape conditions. Renderer recovery freezes
audio and reuses the same gate. A frame's arrival alone cannot restart playback.

## Cache implementation

- 1 MiB network windows, 64 KiB verified disk pages, incremental delivery before
  a complete window has arrived. Up to two windows can be active.
- 32 MiB memory LRU per session; shared 512 MiB disk LRU. Disk records include a
  SHA-256 payload checksum. Only complete, validated responses persist pages.
- Identity includes account scope, stable file ID, size and validator. SHA1
  metadata supplies the validator where available. Without a reliable validator,
  cross-session disk reuse is disabled. 115's current auth model lacks a stable
  account identifier, so a hashed authenticated-session namespace conservatively
  isolates accounts; token rotation may reduce reuse. Credentials are not stored.
- Same-window reads join an existing request; adjacent small reads share the
  remainder of the window. Demand reads initiate requests; no separate speculative
  whole-file downloader competes with playback.
- Exact Content-Range/start/end/total/content-length and strong ETag consistency
  are checked. Nonzero Range + 200 is rejected. Offset-zero 200 is allowed only
  for a verified small whole resource (at most 1 MiB). 416 is EOF only when its
  verified size and requested offset prove EOF.
- Finite retry and a single shared refresh attempt for 401/403. Cancellation,
  timeout, protocol failure, changed source and genuine EOF are separate paths.
- Cross-origin redirects use a fresh URLRequest and discard all original
  credentials, including custom headers. HTTPS downgrade is rejected.
- Clearing cache cancels the current session, deletes off MainActor, and reopens
  at the same position/intent. Disk epochs reject writes from old downloads.

Real HTTP request/status counts, network bytes, memory/disk hit bytes, misses,
refreshes and cancellations are separate from AVIO bytes and packet jumps.
No packet position count is presented as an HTTP request count.

## Subtitle implementation and limits

Pinned static dependencies: libass 0.17.4, FriBidi 1.0.16, HarfBuzz 10.2.0 and
FreeType 2.13.3. Sources and hashes are in
`Dependencies/Subtitles/build-apple.sh`; upstream source archives, licenses and
the build script are bundled with the private CinevaFFmpeg framework. FreeType
uses the FTL license. Credit: portions of this software are copyright The
FreeType Project (https://freetype.org). All rights reserved.

The subtitle packet queue has an independent worker and 2 MiB / 128-packet limit.
ASS styles, fonts, positioning and animation use libass. PGS palette bitmaps use
their display intervals and original coordinates. Bitmap retention is limited
to 32 events / 32 MiB. Fonts are bounded separately. Overflow reports a subtitle
error instead of permanently blocking audio/video. The overlay is rendered off
MainActor at up to 10 Hz; normal video remains native YUV/HDR.

External ASS/SSA retain their script styles. External SRT/WebVTT pass through
FFmpeg's subtitle decoder instead of stripping markup into plain text. Text input
is bounded to 4 MiB; UTF-8, UTF-16 and Windows-1252 decoding are available. The
existing global subtitle offset uses the same audio master clock. Subtitles are
cleared on generation changes. External text events remain available for backward
seek; streaming internal events are pruned and rebuilt through demux seek.

External SUP sidecars up to 8 MiB are retained in bounded memory and decoded
with only a five-second lookahead. SUP seeking rescans memory without requesting
the video from its beginning. Larger sidecars are rejected explicitly. Encoding
selection includes UTF-8, UTF-16, GB18030, Big5 and Windows-1252; automatic
detection is necessarily heuristic. PiP subtitle composition remains unverified
and is not included by the ordinary overlay. Existing
115 sidecar discovery is not expanded by this change; internal tracks are exposed.

## Capability / evidence matrix

| Feature | Implementation | Runtime evidence |
|---|---|---|
| Original-file FFmpeg playback with audio | Real Swr/PCM/AVAudioEngine, normal screen | Device acceptance pending |
| Cached HTTP seek | Custom AVIO actually connected | Controlled HTTP checks passed for build 50 |
| 0.5–2x pitch-preserving speed | TimePitch + clock/rate handling | Device pitch/sync checks pending |
| Multi-audio selection | Decoder switch + coordinated seek + failure restore | Device multi-track checks pending |
| Internal SRT/WebVTT/ASS/SSA/PGS | Separate worker + libass/bitmap rendering | Build 51 device checks pending |
| External text subtitles | Raw text decode + styled renderer | Styling/encoding checks pending |
| External PGS/SUP | Bounded 8 MiB input, separate worker, five-second lookahead | Device palette/timing/seek validation pending |
| HDR10/HLG | 10-bit native buffers + color metadata + EDR request | Actual display output unverified |
| HDR on unsupported display | iOS 18+ Core Image Reference White tone mapping to sRGB, bounded 4-buffer pool; unsupported/unknown headroom falls back | Color/brightness and throughput need device validation |
| Dolby Vision | Metadata detection + bounded native fallback | Native output depends on format/device; not guaranteed |
| Atmos | Decoder-profile detection; current output is stereo PCM | No Atmos bitstream output claimed |
| PiP | Actual sample-buffer content source + delegate controls | Device lifecycle checks pending; no subtitle overlay |
| Background / lock screen | Audio session + existing remote-command coordinator on active engine | Device route/interrupt checks pending |
| AirPlay | Existing system route selection retained | Audio routing, mirroring and remote video are not equivalent; unverified |

Native compatibility fallback is not evidence that arbitrary authenticated URLs,
Dolby formats, AirPlay or HDR will work. Failure stays visible; no universal
compatibility or millisecond seeking claim is made.

HDR-eligible output keeps the original native YUV/10-bit chain. Only an ineligible
HDR display uses the separate off-main Core Image path. The source headroom must
be known, `CIToneMapHeadroom` targets 1.0, and rendering produces actual sRGB pixels
with SDR attachments; this is not a metadata relabel. iOS 17 or unknown headroom
uses explicit compatibility fallback. Apple algorithm reference:
https://developer.apple.com/videos/play/wwdc2024/10177/

## Reproducible checks and build evidence

Windows source gate: `python Tests/preflight.py` and `git diff --check`.
These are not Swift type checks or device tests.

The **existing** `build-unsigned-ipa.yml` performs:

1. Pinned Apple FFmpeg/dependency builds and private-export checks.
2. 19 production buffer-policy checks.
3. `swiftc` on the production RangeCoordinator and RangeChecks, with a real local
   Python HTTP fixture: valid 206, bounded 200, rejected 200/wrong range/416,
   ETag change, URL refresh, cross-origin header isolation, memory/disk identity,
   incremental read, generation cancellation, truncation and timeout.
4. `xcodebuild -workspace Gallery115.xcworkspace -scheme Gallery115
   -configuration Release -sdk iphoneos -derivedDataPath build
   CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build`.
5. Unsigned IPA packaging. No separate regression workflow or artifact was added.

Build 50, commit 4f51c6a: **19 buffer checks + 38 HTTP checks + iOS build passed**.
IPA: https://github.com/sandmiyt/115/actions/runs/36296669224
This proves compilation/packaging and the local protocol checks, not playback of
the private 115 file. Build 51 adds two cache-clear epoch checks and subtitles;
build 51 (b0c55ee) passed 19 buffer checks, 39 transport/integrity checks and iOS
compilation: https://github.com/sandmiyt/115/actions/runs/36297394080
The integrity assertion count varies when CFNetwork delivers a prefix before a
truncated response; both verified-prefix and bounded-error outcomes are checked.
Build 53 includes lazy font discovery, audio-session category correction, explicit
background-audio video suppression and a verified 64-bit/416 boundary test.
Final status must be recorded for its exact revision.

## Same-file device acceptance still required

The diagnostic page retains these modes using the same source URL and position:
video-only standard; video-only sequential; audio/video old HTTP; audio/video
Custom AVIO; audio decode without output. Full diagnostic runs do not write
watch history. Rows remain visible, including incomplete observations.

For the original problem file, record cold cache separately from warm cache.
Compare first frame/startup, 10-second buffering count, real HTTP/network/cache
counters, AVIO bytes, packet jumps, read latency, A/V runway and clock offset.
Then play audio-enabled cached mode for at least 20 minutes (or the file length),
pause/resume, seek backward/forward, change 0.5/1/2x and audio/subtitle tracks,
test EOF, background, headphones/Bluetooth interruptions and PiP controls.

No private-video cold/warm measurements or 20-minute results have been obtained
on this Windows host. Those cells are deliberately not filled with fixture data.
