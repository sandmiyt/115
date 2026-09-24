import Foundation

/// Counts distinct playback refills, not startup, pauses or user seeks.
struct PlaybackRecoveryPolicy {
  enum Reason: Equatable {
    case slowStart, repeatedRefills, prolongedWait
  }

  private var refillStarts: [TimeInterval] = []

  mutating func recordRefill(at now: TimeInterval) {
    guard now.isFinite else { return }
    refillStarts.removeAll { now - $0 > 60 || $0 > now }
    refillStarts.append(now)
  }

  func reason(now: TimeInterval, wait: TimeInterval, hasStarted: Bool,
    seeking: Bool, fastStart: Bool) -> Reason? {
    guard now.isFinite, wait.isFinite, wait >= 0 else { return nil }
    // A slow resume-position seek is not a failed initial open either.
    if seeking { return nil }
    if !hasStarted && fastStart && wait >= 10 { return .slowStart }
    if hasStarted && refillStarts.filter({ (0...60).contains(now - $0) }).count >= 2 {
      return .repeatedRefills
    }
    if wait >= 15 { return .prolongedWait }
    return nil
  }
}

/// Only initial startup may bypass AVPlayer's stall prediction. Once playback
/// has begun, repeated playImmediately calls defeat its refill hysteresis.
enum PlaybackStartupPolicy {
  static func canLoadAuxiliary(stableSeconds: Double, buffered: Double?,
    remaining: Double, rate: Double, forwardTarget: Double = .infinity) -> Bool {
    guard stableSeconds.isFinite, stableSeconds >= 5, rate.isFinite, rate > 0,
      !remaining.isNaN, remaining > 0 else { return false }
    // VLC does not expose a contiguous buffer. Require sustained playback
    // there instead of inventing a buffer measurement.
    guard let buffered else { return true }
    guard !forwardTarget.isNaN, forwardTarget > 0 else { return false }
    return buffered.isFinite
      && buffered >= min(15 * min(max(rate, 0.5), 2), forwardTarget * 0.75, remaining)
  }

  static func canStartImmediately(hasStarted: Bool, attempted: Bool, seeking: Bool,
    fastStart: Bool, original: Bool, buffered: Double, remaining: Double,
    rate: Double, observedBitrate: Double?, requiredBitrate: Double?) -> Bool {
    guard fastStart, !hasStarted, !attempted, !seeking,
      buffered.isFinite, buffered >= 0, rate.isFinite, rate > 0,
      !remaining.isNaN, remaining > 0 else { return false }
    let speed = min(max(rate, 0.5), 2)
    let threshold = min((original ? 8.0 : 3.0) * speed, remaining)
    guard threshold > 0.1, buffered >= threshold else { return false }
    // Access-log throughput is historical, not instantaneous, but a known
    // deficit is sufficient reason to leave startup to AVPlayer.
    if let observed = observedBitrate, let required = requiredBitrate,
      observed.isFinite, required.isFinite, observed > 0, required > 0,
      observed < required * speed * 1.15, buffered < remaining { return false }
    return true
  }

  static func vlcCacheMilliseconds(original: Bool, disc: Bool, fastStart: Bool) -> Int {
    if original || disc { return fastStart ? 5_000 : 8_000 }
    return fastStart ? 1_800 : 3_500
  }
}
