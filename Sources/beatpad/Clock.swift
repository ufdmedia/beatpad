import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - State, clock, errors

final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var kicks = 0
    private var accents = 0
    private var lastHit = -Double.infinity
    private var lastKind = Kind.kick
    var stopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func fired(_ hit: Hit) {
        lock.lock(); defer { lock.unlock() }
        if hit.kind == .kick { kicks += 1 } else { accents += 1 }
        lastHit = now(); lastKind = hit.kind
    }
    func snapshot() -> (kicks: Int, accents: Int, flash: String) {
        lock.lock(); defer { lock.unlock() }
        return (kicks, accents, now() - lastHit < 0.080 ? (lastKind == .kick ? "●" : "·") : " ")
    }
}
let state = RunState()
var stopRequested: Bool { state.stopRequested }
let timebase: mach_timebase_info_data_t = {
    var value = mach_timebase_info_data_t()
    mach_timebase_info(&value)
    return value
}()
let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
let t0 = mach_absolute_time()
func now() -> Double {
    let origin = t0
    return Double(mach_absolute_time() - origin) / ticksPerSecond
}
/// Polls sleep throughout; precision waits spin only for their specified final margin.
/// Short sleeps also make Ctrl-C prompt.
func waitUntil(_ t: UInt64, spinMargin: Double = 0.0015) {
    let margin = UInt64(spinMargin * ticksPerSecond)
    while !stopRequested {
        let n = mach_absolute_time()
        if n >= t { return }
        if t - n > margin {
            usleep(useconds_t(max(1, min(50_000, Double(t - n - margin) / ticksPerSecond * 1e6))))
        }
    }
}
/// Signed offsets must not wrap UInt64 (negative --offset-ms is allowed).
func hostTime(_ base: UInt64, plus seconds: Double) -> UInt64 {
    let value = Double(base) + seconds * ticksPerSecond
    if value <= 0 { return 0 }
    if value >= Double(UInt64.max) { return UInt64.max }
    return UInt64(value)
}
func fail(_ message: String, headline: String = "beatpad can't play on this Mac.", code: Int32 = 1) -> Never {
    if isatty(STDERR_FILENO) == 1 { FileHandle.standardError.write(Data("\u{1B}[?25h".utf8)) }
    let body = message.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n")
    FileHandle.standardError.write(Data(("\n  " + headline + "\n\n" + body + "\n\n").utf8))
    exit(code)
}
func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message); see beatpad --help\n".utf8))
    exit(64)
}

