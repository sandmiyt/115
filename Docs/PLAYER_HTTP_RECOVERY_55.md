# Cineva 2.2.9 (55): HTTP status recovery before AVIO failure

Baseline: f93c627 documentation / e729777 code, build 54. The user's message is
the specification; no Markdown attachment or experimental patch was supplied.
Only the shipping `Gallery115/` tree is changed. The historical untracked `115/`
directory remains untouched.

## Confirmed defect and repair

Build 54 classified HTTP 500 as `malformedResponse`, immediately set fatalError,
then the C read callback mapped the negative transport result to FFmpeg EIO.
This could terminate av_read_frame before recovery and blocked verified pages.

Build 55 distinguishes:

- 500 / 502 / 503 / 504: retryable `serverError` attempt failure.
- 429: retryable `rateLimited`, with its own default backoff.
- Other non-media statuses: `httpStatus` (401/403 keep bounded URL refresh).
- Invalid 206 / Content-Range / body: `malformedResponse`; integrity failures,
  source changes, metadata conflicts and credential policy failures stay strict.

Recovery stays inside the synchronous background AVIO read. The initial Range
request and subsequent attempts share a three-attempt cap and the unchanged
nine-second monotonic budget. Authentication refresh cannot reset that cap.
500-class default delays are 0.25 / 0.5 seconds; 429 defaults to 1 / 2 seconds.
Valid Retry-After delay-seconds or HTTP-date sets a minimum wait. If that wait
cannot fit the remaining budget, recovery exhausts without retrying too early or
extending the timeout. Network callbacks progress independently; condition waits
release the lock, and stop/seek broadcasts immediately cancel the old generation.

Requests resume at the current missing offset. There is no restart from byte zero,
whole-file download, additional concurrency, decoder change or silent fallback.
HTTP error bodies are rejected before media delivery. Existing verified cache
pages remain available while status recovery is pending. Every successful retry
still passes the original range, size, ETag and file-identity validation.

The final negative result is returned only on exhaustion (or a nonrecoverable
integrity/security error). The existing immutable failure snapshot and fallback
then apply. A 500 alone is not evidence that the media changed.

## Evidence and diagnostics

Each recovery retains at most three attempts with status, exact offset,
Retry-After, planned/actual wait and total elapsed time. Outcomes distinguish
`recovering`, `recovered`, `exhausted`, `cancelled`, and `rejected` (integrity).
The recovery report is shown in normal FFmpeg diagnostics and frozen failure
snapshots. Recovery clears its previous lastIssue/lastError; prior HTTP 500 does
not remain a current failure after successful media delivery. Error pages,
credentials, signed URLs and raw Retry-After text are not logged.

## Changed files

- `Gallery115/PlayerCore/RangeCoordinator.swift`: status classification, bounded
  recovery state, cancellable waits, diagnostics and generation-scoped refresh.
- `Gallery115/PlayerCore/FFmpegPlayerEngine.swift`: publish recovery diagnostics.
- `Tests/PlayerTransport/range_server.py`, `RangeChecks.swift`: deterministic
  transient/status fixtures, byte checks and concurrent cancellation/cache tests.
- `Gallery115.xcodeproj/project.pbxproj`: Debug/Release build number 55.

Native audio, VideoToolbox, subtitles, speed, PiP and stable player UI are not
rewritten. C customRead keeps its existing final error mapping; temporary HTTP
statuses no longer reach it prematurely.

## Validation

Windows source gate: `python -X utf8 Tests/preflight.py` and `git diff --check`.
These do not establish Swift type correctness or actual iPhone playback.

The existing macOS IPA job runs production RangeCoordinator through swiftc and
the local HTTP fixture, retains the buffer-policy checks, and performs unsigned
iPhone Release xcodebuild. Added cases include one/two 500s then 206; perpetual
500; 502/504; 503/429 Retry-After seconds and date; excessive delay; nonretryable
404; combined 500/403 attempt cap; stop and seek during backoff; old pages read
while another gap recovers; ETag change after a retry. Original short/nonaligned
206, identity, body integrity, timeout, refresh and credential isolation remain.

Final tested code: `d55b74330728959a611df770a7d6162f322b446d`, build **2.2.9 (55)**.
On 2026-09-27 the existing macOS job passed **19 buffer-policy assertions,
1034 transport/byte-integrity assertions, iPhone Release compilation and IPA
packaging**. This includes two readers coalescing onto exactly one retry.

- Run: https://github.com/sandmiyt/115/actions/runs/36310413255
- IPA: https://github.com/sandmiyt/115/actions/runs/36310413255/artifacts/10928762427
- Outer artifact ZIP: 59,463,624 bytes, `Gallery115-unsigned-ipa`.

The assertion count includes per-delivery byte checks and varies with network
chunk delivery; it is not a count of independent scenarios. Existing compiler
warnings remain. A later documentation-only commit does not alter this built code.
Local HTTP fixtures are synthetic byte patterns, not private 115 media or an
audio playback test.

## Device acceptance remains unmeasured

No connected iPhone or private playback URL is available on this Windows host.
Use the original problematic video in the normal FFmpeg engine with sound;
check startup/history seek, prolonged playback and seeking. Record recovery
diagnostics and any frozen failure. AVPlayer fallback success is not counted as
FFmpeg repair success. No claim of private-video/device acceptance is made.

Protocol references: RFC 9110 section 10.2.3 (Retry-After),
https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3 ; RFC 6585 section 4 (429),
https://www.rfc-editor.org/rfc/rfc6585.html#section-4 .
