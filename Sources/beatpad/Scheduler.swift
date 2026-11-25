import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Pure live motor scheduler (all times in the caller's clock domain)
enum HapticAction {
    case fireThump(PlannedBeat, at: Double)
    case playMelody(hz: Double, duration: Double, level: Double)
    case wait(until: Double)
}
struct LiveHapticScheduler {
    static let commit = 0.020, late = 0.020, guardTime = 0.003, poll = 0.005, chunk = 0.020, minimumLevel = 0.02
    var melodyOnly = false, kickOnly = false
    private(set) var lastBeat = -Double.infinity
    private var busyUntil = -Double.infinity
    init(melodyOnly: Bool = false, kickOnly: Bool = false) {
        self.melodyOnly = melodyOnly; self.kickOnly = kickOnly
    }
    // The executor reports the actual end because voice() can stop at its cutoff
    // or skip a muted thump; neither should leave a nominal-duration dead zone.
    mutating func thumpFinished(at time: Double) { busyUntil = time }
    mutating func nextAction(now: Double, nextBeat: PlannedBeat?, melody: MelodyFrame, allowed: Bool = true) -> HapticAction {
        if !allowed {
            if let beat = nextBeat, beat.time - now <= Self.commit { lastBeat = max(lastBeat, beat.time) }
            busyUntil = now
            return .wait(until: now + Self.poll)
        }
        if now < busyUntil { return .wait(until: busyUntil) }
        let beat = nextBeat.flatMap { $0.time > lastBeat ? $0 : nil }
        if let beat, !melodyOnly, beat.time - now <= Self.commit {
            lastBeat = beat.time
            if beat.time - now >= -Self.late, let kind = beat.kind, !(kickOnly && kind == .accent) {
                busyUntil = max(now, beat.time) + (kind == .kick ? kickDuration : accentDuration)
                return .fireThump(beat, at: beat.time)
            }
            return .wait(until: now)
        }
        let fire = melodyOnly ? Double.infinity : (beat?.time ?? .infinity)
        if let hz = melody.hz, hz.isFinite, hz > 0, melody.strength >= Self.minimumLevel {
            let desiredCycles = max(1, (Self.chunk * hz).rounded())
            let available = fire - Self.guardTime - now
            let cycles = min(desiredCycles, floor(available * hz + 1e-9))
            if cycles >= 1 {
                let duration = cycles / hz
                busyUntil = now + duration
                return .playMelody(hz: hz, duration: duration, level: melody.strength)
            }
            return .wait(until: max(now, fire - Self.commit))
        }
        return .wait(until: min(now + Self.poll, max(now, fire - Self.commit)))
    }
}

