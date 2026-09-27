import Foundation

/// Retained legacy buffer-policy assertions. Not linked into the shipping app.
struct DiagnosticBufferPolicy {
  let startupBufferTarget = 0.75
  private(set) var rebufferTarget = 2.0
  private(set) var stallCount = 0
  private(set) var runway = 0.0
  private(set) var resumeTarget = 0.75
  private(set) var capacityLimited = false
  private var rebuffering = false
  private var consecutiveStalls = 0
  private var lastStallAt: Double?
  private var waitingSince = 0.0

  mutating func prepare(at now: Double) {
    rebuffering = false
    waitingSince = now
    runway = 0
    resumeTarget = startupBufferTarget
    capacityLimited = false
  }

  mutating func starved(at now: Double) {
    consecutiveStalls = lastStallAt.map { now - $0 <= 30 ? consecutiveStalls + 1 : 1 } ?? 1
    lastStallAt = now
    stallCount += 1
    rebufferTarget = min(5, Double(consecutiveStalls + 1))
    rebuffering = true
    waitingSince = now
    capacityLimited = false
  }

  mutating func canResume(compressed: Double, decoded: Double, pending: Double,
                          submitted: Double, hasFrame: Bool, ioLatency: Double,
                          eof: Bool, backpressured: Bool, now: Double) -> Bool {
    func valid(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    runway = valid(compressed) + valid(decoded) + valid(pending) + valid(submitted)
    if rebuffering { rebufferTarget = max(rebufferTarget, min(5, 2.5 * valid(ioLatency))) }
    resumeTarget = rebuffering ? rebufferTarget : startupBufferTarget
    capacityLimited = false
    guard hasFrame, runway > 0 else { return false }
    if eof { return true } // Drain a short clip/tail; waiting for two seconds would deadlock.
    if runway >= resumeTarget { return true }
    // A high-bitrate stream can fill the existing byte/packet cap before reaching
    // the time target. Do not enlarge RAM or wait forever. Disclose the exception.
    if backpressured, valid(decoded) > 0, now - waitingSince >= resumeTarget {
      capacityLimited = true
      return true
    }
    return false
  }
}
