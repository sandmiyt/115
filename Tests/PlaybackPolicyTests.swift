import Foundation

// Compiles the shipping Swift policies directly. No AVPlayer/CDN simulation
// is presented as device evidence. Run this binary before the IPA build.
@main
enum PlaybackPolicyTests {
  static func main() {
    var checks = 0
    func check(_ value: Bool, _ name: String) {
      guard value else { fatalError("FAIL: \(name)") }
      checks += 1
      print("PASS: \(name)")
    }
    func start(started: Bool = false, attempted: Bool = false, seeking: Bool = false,
      fast: Bool = true, original: Bool = true, buffer: Double = 8,
      remaining: Double = 7_200, rate: Double = 1,
      observed: Double? = nil, required: Double? = nil) -> Bool {
      PlaybackStartupPolicy.canStartImmediately(hasStarted: started, attempted: attempted,
        seeking: seeking, fastStart: fast, original: original, buffered: buffer,
        remaining: remaining, rate: rate, observedBitrate: observed, requiredBitrate: required)
    }

    check(!start(buffer: 3), "Original cannot be forced to start with only three seconds")
    check(start(), "Original initial startup with eight seconds")
    check(start(original: false, buffer: 3), "Transcode keeps bounded fast startup")
    check(!start(fast: false, buffer: 120), "Fast-start opt-out is respected")
    check(!start(attempted: true, buffer: 120), "Only one forced start per item")
    check(!start(seeking: true, buffer: 120), "Never force playback during an in-flight seek")
    check(!start(started: true, buffer: 12), "First refill retains AVPlayer stall prediction")
    check(!start(started: true, buffer: 20), "Repeated refill cannot restart forced-play loop")
    check(!start(started: true, seeking: false, buffer: 120), "Completed seek does not restore forced start")
    check(!start(buffer: 8, rate: 2) && start(buffer: 16, rate: 2), "Double speed requires double runway")
    check(start(buffer: 4, rate: 0.5), "Half speed uses a proportionate runway")
    check(!start(observed: 40, required: 80), "Known throughput deficit prevents forced startup")
    check(!start(observed: 80, required: 80), "Startup retains throughput headroom")
    check(start(observed: 100, required: 80), "Adequate measured throughput permits initial startup")
    check(!start(buffer: 16, rate: 2, observed: 100, required: 80), "Throughput guard scales with speed")
    check(start(buffer: 2, remaining: 2, observed: 10, required: 80), "Fully buffered short tail can start")
    check(!start(buffer: 1, remaining: 2), "Partially buffered short tail waits")
    check(start(remaining: .infinity), "Unknown duration still supports bounded startup")
    check(!start(buffer: .nan) && !start(buffer: .infinity) && !start(rate: .nan)
      && !start(remaining: .nan) && !start(remaining: 0), "Invalid samples cannot trigger playback")

    // Sample 2 hours of repeated refill opportunities at multiple speeds.
    // This is a state-invariant test, not a throughput/performance benchmark.
    for rate in [0.5, 1.0, 2.0] {
      for time in stride(from: 10.0, to: 7_200, by: 0.5) {
        precondition(!start(started: true, buffer: time.truncatingRemainder(dividingBy: 60),
          remaining: 7_200 - time, rate: rate))
      }
    }
    check(true, "Two-hour refill/seek state trace never forces restart after playback")

    let ranges = PlaybackBufferPolicy.normalized([
      .init(start: 0, end: 4), .init(start: 30, end: 60), .init(start: 3, end: 6),
      .init(start: .nan, end: 100)])
    check(PlaybackBufferPolicy.contiguousEnd(at: 1, ranges: ranges) == 6,
      "Distant downloaded range cannot inflate local runway")
    check(PlaybackBufferPolicy.contiguousEnd(at: 10, ranges: ranges) == 10,
      "A gap has no playable contiguous reserve")
    check(!start(buffer: PlaybackBufferPolicy.contiguousEnd(at: 1, ranges: ranges) - 1),
      "Startup refuses a false reserve across a range gap")
    let memory: UInt64 = 4 * 1_024 * 1_024 * 1_024
    let highBitrate = PlaybackBufferPolicy.forwardDuration(bitrate: 80_000_000,
      stalls: 0, rate: 1, memoryBytes: memory)
    check(highBitrate > 8 && highBitrate <= Double(memory) / 24 * 8 / 80_000_000,
      "High-bitrate prefetch exceeds startup reserve within estimated memory budget")

    var recovery = PlaybackRecoveryPolicy()
    check(recovery.reason(now: 30, wait: 30, hasStarted: false, seeking: true, fastStart: true) == nil,
      "Pending history-position seek cannot be mistaken for slow initial open")
    recovery.recordRefill(at: 10)
    check(recovery.reason(now: 11, wait: 1, hasStarted: true, seeking: false, fastStart: true) == nil,
      "A single refill does not switch engines")
    recovery.recordRefill(at: 20)
    check(recovery.reason(now: 21, wait: 1, hasStarted: true, seeking: false, fastStart: true) == .repeatedRefills,
      "Distinct repeated refills still allow same-original VLC recovery")
    check(recovery.reason(now: 21, wait: 1, hasStarted: true, seeking: true, fastStart: true) == nil,
      "Refill history does not switch engines during a seek")
    check(recovery.reason(now: 81, wait: 1, hasStarted: true, seeking: false, fastStart: true) == nil,
      "Old refill history expires")
    check(recovery.reason(now: 81, wait: 15, hasStarted: true, seeking: false, fastStart: true) == .prolongedWait,
      "Sustained stalls retain recovery")

    check(!PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 1, buffered: 30, remaining: 7_200, rate: 1),
      "One advancing frame cannot release auxiliary traffic")
    check(!PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 10, buffered: 5, remaining: 7_200, rate: 1),
      "Thin original runway blocks auxiliary traffic")
    check(PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 5, buffered: 15, remaining: 7_200, rate: 1),
      "Stable playback plus reserve permits auxiliary traffic")
    check(!PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 5, buffered: 15, remaining: 7_200, rate: 2),
      "Auxiliary reserve scales with speed")
    check(PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 5, buffered: 9,
      remaining: 7_200, rate: 1, forwardTarget: 12),
      "Memory-limited high-bitrate prefetch cannot permanently starve metadata")
    check(PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 5, buffered: 2, remaining: 2, rate: 1),
      "Fully buffered tail does not starve metadata")
    check(!PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 4, buffered: nil, remaining: 7_200, rate: 1)
      && PlaybackStartupPolicy.canLoadAuxiliary(stableSeconds: 5, buffered: nil, remaining: 7_200, rate: 1),
      "VLC uses stable playback without fabricating a buffer measurement")
    check(PlaybackStartupPolicy.vlcCacheMilliseconds(original: true, disc: false, fastStart: true) == 5_000,
      "VLC original has a five-second cache")
    check(PlaybackStartupPolicy.vlcCacheMilliseconds(original: true, disc: false, fastStart: false) == 8_000,
      "VLC steady mode has an eight-second cache")
    check(PlaybackStartupPolicy.vlcCacheMilliseconds(original: false, disc: false, fastStart: true) == 1_800,
      "Transcode VLC cache remains unchanged")
    print("Playback policy tests: \(checks) passed")
  }
}
