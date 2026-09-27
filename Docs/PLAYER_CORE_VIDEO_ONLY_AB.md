# Cineva 2.2.9 (49): remote MP4 video-only A/B

## Scope and current evidence

This continues build 48; it is an experimental FFmpeg validation change, not a
replacement of the daily AVPlayer/VLC players. Login, browsing, history,
subtitles, PiP and AirPlay paths are unchanged.

Build 48 device evidence: H264 Main 1920x1080 + AAC, working VideoToolbox output,
zero dropped frames / renderer recoveries / terminal decode errors; about
0.78–0.81 s per av_read_frame, 417 backward packet-position jumps, 377 forward
gaps >1 MiB, and about 1.07 s compressed video queued. This supports an I/O
starvation hypothesis. Packet positions alone do not establish HTTP request
count or prove the private file's physical track layout.

**Status: suspected remote MP4 track-interleave I/O bottleneck; device A/B pending.**
Only after same-file, same-position device A/B repeatedly shows substantially
fewer jumps, faster reads, deeper video runway and sustained B playback should
the result be recorded as: `Confirmed remote MP4 track-interleave I/O bottleneck`.
A/B changes both audio participation and MOV ordering; this is a combined
diagnostic intervention, not a measurement isolating each switch independently.

## Session and demux changes

- `CinevaFFmpegSessionOptions.videoOnly` is true by default at the Swift validation
  entry. B does not create an audio decoder; `audioIndex = -1` excludes audio from
  the bounded packet queue. Audio codec metadata remains visible.
- Non-video streams are set to `AVDISCARD_ALL` before stream probing, then all
  unselected streams are discarded. Probe `codec_whitelist` contains only actual
  compiled video decoders so libavformat cannot internally initialize AAC either.
- Only when the actual input format pointer equals `av_find_input_format("mov")`
  (MOV/MP4/M4A/3GP/3G2/MJ2 family), B sets private `interleaved_read=0` before probing.
  A uses `videoOnly=false` and `interleaved_read=1`; audio decode/count support stays
  intact. Other demuxers show N/A; they never receive this private MOV option.
- MOV checks stream discard before reading sample bytes. B avoids audio-only
  sample seeks/reads. Container headers, shared AVIO buffers and forward read-ahead
  can still include bytes belonging to audio; this is not a zero-audio-wire-byte
  claim. No new huge short_seek_size, timeout, or queue budget was introduced.
- Frames cross the C/Swift boundary as pixel buffer + PTS + duration + generation.
  Positive finite AVFrame.duration uses AVFrame.time_base (stream timebase fallback).
  Only unavailable/invalid duration uses 1/guessedFPS, then 30 FPS if no guess exists.
  Display sample duration and decoded queue accounting use the same actual duration.

## Rebuffer policy

The first frame can preview with timebase rate 0. Submitting it does not release
`waitingForData`. Only the controller's explicit resume decision advances time.

- Startup / explicit seek: 0.75 s estimated playable runway.
- First real starvation: at least 2 s; repeated starvation within 30 s raises the
  target to 3, 4, then 5 s. After a quiet interval escalation restarts at 2 s;
  total `stallCount` is retained. Explicit seeks / renderer recovery do not add stalls.
- During rebuffer the target also accounts for 2.5 times max(current I/O elapsed,
  last av_read_frame duration), capped at 5 s. A target never falls mid-wait.
- Runway = compressed video duration + decoded queue duration + held Swift frame
  duration + remaining submitted display duration. Audio time and pre-target packet
  preroll do not contribute. An available decoded/display frame is also required.
- Compressed duration is an estimate of decodable video, not proof of contiguous
  display coverage for corrupt timestamps. The page says “估算可播放余量”.
- EOF allows a shorter remaining tail to drain. If the existing 16 MiB / 512-packet
  limit fills below target, decoded frames exist, and at least a target-length wait
  elapsed, resume with existing capacity and show an explicit capacity-limited
  diagnostic. This avoids a permanent producer/consumer wait without growing RAM.
- Existing compressed 8 s / 16 MiB / 512-packet limits and decoded 3/6-frame limits
  remain. Renderer recovery still has its existing bounded retry policy.

## Diagnostics and A/B procedure

Live and copied diagnostics keep the original fields and add:

- `Video-only diagnostic`, `MOV interleaved read: ON/OFF/N/A`, `audio demux: ON/OFF`.
- `backwardJumpBytesTotal`, `largestBackwardJump`, `forwardGapBytesTotal`,
  `largestForwardGap` (bytes; forward totals include small gaps as well).
- `packetReadCount`: number of av_read_frame calls, including EOF/errors/cancelled
  calls; average/max durations cover those calls and exclude queue waiting,
  open/probe/seek. These are not HTTP transaction latencies.
- Decoded duration, startup/rebuffer target, cumulative stall count and last
  assessed runway; bounded-capacity exception if applicable.
- Actual HTTP requests / Range count / 200/206/416 / cache hit/miss explicitly
  **不可获得** until Custom AVIO instrumentation exists. AVIO bytes are library-read
  bytes, not exact on-wire transfer size. Packet jumps are never HTTP requests.

On the FFmpeg validation page, leave hardware preference fixed. At the problem
position (e.g. around 632 s), choose “设为当前进度并重测”. B is the default. Let it
actually start, then wait at least 10 wall-clock seconds without pausing/seeking.
Switch to A and wait the same way. Both restart using the same VideoSource URL,
headers and fixed target; switching does not use the advancing playback position.
Repeat B/A when possible to reduce transient CDN bias; a cold/warm CDN effect is
not controlled by this UI. Expired URLs fail visibly rather than silently changing
the source of a comparison. Hardware preference and target are recorded per trial.

The observation window begins on first actual clock resume and includes buffering
time. First-frame enqueue latency and actual-start latency are reported separately.
At 10 s the comparison row freezes: buffering count, cumulative session AVIO bytes,
packet jumps, average/max read duration, and current compressed queue snapshot.
Manual pause/seek, premature stop, error or early EOF marks an unfinished trial;
already-completed rows remain valid. Full live diagnostics continue after the
comparison freezes. Previous rows remain visible for this page lifetime and all
rows are included in “复制播放诊断”; leaving the page does not persist them.

## Next stage: Custom AVIO design (not implemented in this build)

```text
Custom AVIOContext (read/seek/size callbacks; generation-aware)
  -> RangeCoordinator (demand priority, coalescing, cancellation, URL lease)
     -> SegmentedCache
        -> bounded memory blocks
        -> bounded disk blocks + transactional index / LRU
        -> HTTP Range / 115
```

1. Begin with 1 MiB blocks, configurable to 2 MiB after measurements. Align byte
   requests, merge adjacent missing blocks into at most 4 MiB transfers. Demand
   reads precede optional adjacent prefetch; cap network concurrency (initially 2).
2. Coalesce identical/overlapping block requests per stable file identity. Each
   waiter owns its generation/cancellation token; abort underlying HTTP only when
   no current-generation waiter remains. A seek invalidates old delivery, not
   already verified reusable blocks. Close cancels and joins outside the UI thread.
3. Start with 32 MiB RAM and 512 MiB disk configurable caps. Account in-flight and
   pinned blocks in budgets; evict unpinned LRU blocks. If all blocks are pinned,
   backpressure rather than exceeding budget. Atomically publish complete verified
   disk blocks and index entries; partial writes never become cache hits.
4. Identity is provider/account namespace + stable file ID + size + reliable ETag
   or Last-Modified/version validator, never a signed URL. Validate refreshed sources
   against the identity; a changed validator/size invalidates old blocks. Without a
   reliable validator, limit reuse to a verified session and document reduced safety.
5. Validate Content-Range start/end/total, received length and validator for every
   206. A 200 in response to a nonzero Range is a server mismatch; do not download
   from file start as an implicit seek fallback. At offset zero, accept 200 only
   under an explicit bounded sequential policy. For 416, check `bytes */size`: only
   offset at/beyond a verified end is EOF; otherwise invalidate stale size and fail
   or refresh once. Malformed/truncated/mismatched content must not enter cache.
6. Single-flight expired 115 URL refresh through the existing provider boundary,
   bounded to one refresh/retry per operation. Preserve desired byte offset and
   seek generation. Revalidate file identity before reusing blocks. Authentication
   failure is distinct from format failure; redact signed URLs and credentials.
7. Handle redirects per request. Strip Authorization/Cookie and other origin-bound
   credentials across origins; reject TLS downgrade. Apply only provider-approved
   destination-specific headers to a validated redirect destination. Bound redirect
   count and do not put URLs/tokens into cache keys or diagnostics.
8. Add real HTTP request counters, 200/206/416 outcomes, requested/received Range
   bytes, cache hit/miss bytes, coalesced waiters, cancelled generations, occupancy,
   evictions and latency percentiles. Keep these separate from packet-position stats.

Acceptance will need random forward/backward byte reads, adjacent/coalesced reads,
rapid seeks, interrupted responses, expired leases, validator changes, 200/206/416,
cross-origin redirects, bounded storage under pressure, and the same private MP4.

## Validation and remaining functionality

Local preflight checks source structure/grammar only. Xcode on GitHub performs
the real C/Swift compilation, link and unsigned IPA package; final run is reported
with delivery. The existing build step also executes the production Swift buffer
policy using synthetic time (startup, repeated starvation, IO, EOF, capacity,
invalid/VFR durations and seek accounting). No separate regression workflow/job/
artifact is created. Device display timing and the private 115 file remain untested
on this Windows machine.

Formal FFmpeg PlayerCore still lacks audio output/master clock and A/V sync, full
track/subtitle integration, playback-rate audio handling, Dolby Vision handling,
custom AVIO/cache/URL renewal, full lifecycle recovery and PiP/AirPlay integration.
The existing AVPlayer/VLC daily playback paths retain their existing features.
