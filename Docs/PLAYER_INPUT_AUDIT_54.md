# Cineva 2.2.9 (54): bounded input-layer repair

Baseline: code 5bd94c9 / documentation 96e795e, version 2.2.9 (53), shipping
`Gallery115/` target/workspace. The untracked historical `115/` tree is untouched.

The supplied audit document was read. Its referenced reproduction archive was
not supplied; the user confirmed they only received the generated audit prompt.
Its Linux test counts are reported claims, not evidence obtained in this run.
New tests below were written against the production transport, not copied from
the deliberately incomplete NaiveShortExperiment.

## Evidence and root-cause limits

The original source discarded the provider User-Agent on cross-origin redirects,
required the requested final byte on 206, restarted nonaligned missing bytes at
the page boundary, treated listing size as verified EOF and discarded transport
state before exposing the FFmpeg failure. These are confirmed source defects.

Test-first revision 328d4cc failed on the macOS runner at the combined UA and
credential-isolation assertion. Its target returned HTTP 400 when the original
provider UA was absent. This establishes the redirect defect in the production
URLSession implementation; it does not establish that the private 115 URL uses
this redirect behavior.

Red test run: https://github.com/sandmiyt/115/actions/runs/36306900275

## Changes

- `RangeCoordinator.swift`: typed errors and allowlisted value evidence; public
  case-insensitive provider UA preservation; exact demand offsets; requested
  versus received ranges; sparse 64 KiB page coverage; complete-response-only
  assembly and complete-page/tail persistence. A 10,000-byte prefix is a valid
  completed response, not a failed 1 MiB window. Incremental streaming remains.
- Direct mode retains bounded active response buffers only; it bypasses page
  memory/disk caches and refetches consumed bytes on backward reads.
- Listing size is a hint. `AVSEEK_SIZE` returns unknown until HTTP establishes
  length; EOF cannot be synthesized from the listing. A hint conflict is a typed
  `metadataConflict`, with observed and accepted lengths separately recorded.
  This implementation cannot independently revalidate provider file metadata, so
  it fails instead of blindly changing identities or mixing old bytes.
- A new disk identity schema includes the HTTP strong ETag plus existing account,
  stable ID, size and provider validator. Every session verifies HTTP first.
  Version changes or disappearance fail; absent strong validators disable page
  combination/reuse. Valid active responses can still stream without caching.
- Nonzero 200 / large whole-file 200 remains `unsupportedBackend`; no whole-file
  download or hidden input fallback was added. Cross-origin credentials,
  Referer/Origin and validators are not forwarded; each response is independently
  checked against the pinned in-session representation. Downgrades are rejected.
- `CinevaFFmpeg.h` / `CinevaFFmpegSession.c`: bounded callback read/seek facts and
  actual failure function names captured at the native operation. Existing
  FFmpeg negative error mappings remain valid; Swift retains the richer cause.
- `FFmpegPlayerEngine.swift`: freeze immutable build/session/generation/backend,
  stage/function, native error and safe transport evidence before cleanup. Native
  HTTP information unavailable to our callbacks is labelled unavailable.
- `PlayerScreen.swift`: a separate `lastFFmpegFailure` value survives engine
  stop and AVPlayer fallback, with an always-available disclosure/copy action.
  The failure is not overwritten by later cleanup cancellation.
- `DiagnosticBufferPolicy.swift`, `FFmpegDecodeValidationView.swift`,
  `FFmpegDecodeSession.swift`: three audio-enabled input modes (native HTTP,
  custom direct, custom cached), same source/position/hardware preference and
  output pipeline; the existing video-only controls and copyable errors remain.
- `Tests/PlayerTransport/*`: real local HTTP boundary scenarios; no new workflow,
  test artifact or replacement audio/decoder/renderer implementation.

Partial response semantics reference: RFC 9110 section 15.3.7,
https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.7

## Executed checks

Windows: `python -X utf8 Tests/preflight.py` reports zero failures;
`git diff --check` passes. This is source checking, not Xcode or device playback.

The existing GitHub macOS job compiles the production RangeCoordinator with
`swiftc`, launches `Tests/PlayerTransport/range_server.py`, runs RangeChecks and
the existing buffer-policy checks, then invokes the existing unsigned iPhone
Release `xcodebuild` and IPA packaging.

Final tested code revision: `e729777f3d4eb3b88f7b7da33de8f5503f6ada6b`,
Cineva **2.2.9 (54)**, completed successfully on 2026-09-27:

- 19 buffer-policy assertions passed.
- 974 transport / byte-integrity assertions passed, including repeated
  per-read byte checks (not 974 separate playback scenarios).
- Native FFmpeg bridge/dependencies and iPhone Release app compiled; unsigned
  IPA packaged and uploaded, outer artifact ZIP 59,458,274 bytes.
- Run: https://github.com/sandmiyt/115/actions/runs/36307638612
- IPA: https://github.com/sandmiyt/115/actions/runs/36307638612/artifacts/10928047222

An intermediate revision 5da0727 reached the existing truncation assertion and
failed: a delivered prefix could be retried as another prefix. The final version
terminates a response that disconnects after partial delivery; legitimate short
206 completion remains distinct. Its final run passed the truncation check.
Existing compiler warnings remain; a warning-free / Swift 6 migration is not
claimed. A later documentation-only commit does not change this built code.

Coverage includes original transport cases, UA plus credential isolation,
64 KiB and 10,000-byte short prefixes through over 3 MiB, random holes and back
reads, complete-page warm reuse, body/Content-Range mismatch, truncation, timeout,
200/206/416, expired URL refresh, cancellation/generation, hint conflicts,
cross-session HTTP validator changes and missing validators, direct cache bypass,
failure value preservation after close and credential-free diagnostics.

## Unmeasured acceptance

No private signed URL, 115 account or connected iPhone is available here.
Audio-enabled playback of the original problem video has **not** been measured.
Neither a successful HTTP fixture nor AVPlayer fallback is FFmpeg playback proof.
The UI copy action after fail/stop/fallback is implemented and compiled; its
physical-device interaction remains unmeasured.

Install build 54, choose FFmpeg in the ordinary playback settings, and verify
start, history resume and forward/backward seek with sound. Compare the three
audio-enabled input modes from the diagnostic page at the same start point;
record cold versus warm cache, startup, stalls, request counts and A/V offset.
Play at least 20 minutes and copy the frozen failure if a fallback occurs.
No change is claimed to existing HDR, PiP, subtitle or Atmos capability limits.
