import Foundation

/// Counts distinct playback refills, not startup, pauses or user seeks.
struct PlaybackRecoveryPolicy {
  enum Reason: Equatable {
    case slowStart, repeatedRefills, prolongedWait
  }

  private var refillStarts: [TimeInterval] = []

  mutating func recordRefill(at now: TimeInterval) {
    refillStarts.removeAll { now - $0 > 60 || $0 > now }
    refillStarts.append(now)
  }

  func reason(now: TimeInterval, wait: TimeInterval, hasStarted: Bool,
    seeking: Bool, fastStart: Bool) -> Reason? {
    guard now.isFinite, wait.isFinite, wait >= 0 else { return nil }
    if hasStarted && seeking { return nil }
    if !hasStarted && fastStart && wait >= 10 { return .slowStart }
    if hasStarted && refillStarts.filter({ (0...60).contains(now - $0) }).count >= 2 {
      return .repeatedRefills
    }
    if wait >= 15 { return .prolongedWait }
    return nil
  }
}
