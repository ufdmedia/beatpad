import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

func dynamicsTarget(_ db: Double, reference: Double, range: Double) -> Double {
    dynamicsFloor + (1 - dynamicsFloor) * min(1, max(0, (db - reference + range) / range))
}
func listeningVolumeGain(scalar: Double?, muted: Bool?) -> Double {
    if muted == true { return 0 }
    guard let scalar, let _ = muted, scalar.isFinite else { return 1 }
    return min(1, max(0, scalar))
}
func effectiveLevel(master: Double, dynamics: Double, volume: Double, shaping: Double) -> Double {
    min(1, max(0, master * dynamics * volume * shaping))
}
func shouldActuate(_ level: Double) -> Bool { level >= minimumActuationLevel }
func hitShaping(_ hit: Hit) -> Double {
    hit.kind == .kick ? kickBaseLevel + kickStrengthLevel * hit.strength : accentBaseLevel + accentStrengthLevel * hit.strength
}

// Full-band, sample-accurate trailing RMS; only percentile/smoothing updates are
// decimated to 50 ms. This runs on the analysis worker, never the audio callback.
final class DynamicsMeter {
    private var squares: [Double]
    private var index = 0, count = 0, stepCount = 0
    private var energy = 0.0
    private var history: [Double] = []
    private let step: Int, range: Double, rate: Double
    private(set) var gain = 1.0
    init(rate: Double, range: Double) {
        self.rate = rate; self.range = range
        squares = [Double](repeating: 0, count: max(1, Int((rate * dynamicsWindowSeconds).rounded())))
        step = max(1, Int((rate * dynamicsStepSeconds).rounded()))
    }
    func ingest(_ mono: UnsafeBufferPointer<Float>) {
        for value in mono {
            let square = Double(value) * Double(value)
            energy += square - squares[index]; squares[index] = square
            index = (index + 1) % squares.count; count = min(count + 1, squares.count)
            stepCount += 1
            if stepCount == step {
                stepCount = 0
                let db = decibels(sqrt(max(0, energy) / Double(count)))
                history.append(db)
                if history.count > Int(dynamicsHistorySeconds / (Double(step) / rate)) { history.removeFirst() }
                let target = dynamicsTarget(db, reference: percentile(history, dynamicsPercentile), range: range)
                gain += (1 - exp(-Double(step) / rate / dynamicsSmoothingSeconds)) * (target - gain)
                gain = min(1, max(dynamicsFloor, gain))
            }
        }
    }
}

// Look ahead by half a window in file mode. Smooth the whole curve before
// sampling hits, so rests and --start don't alter the section envelope.
func fileDynamics(_ mono: [Float], rate: Double, hits: [Hit], range: Double) -> [Double] {
    guard !mono.isEmpty else { return hits.map { _ in 1 } }
    let step = max(1, Int((rate * dynamicsStepSeconds).rounded()))
    let half = max(1, Int((rate * dynamicsWindowSeconds / 2).rounded()))
    var dbs: [Double] = [], left = 0, right = 0, energy = 0.0
    for center in stride(from: 0, to: mono.count, by: step) {
        let end = min(mono.count, center + half)
        while right < end { energy += Double(mono[right]) * Double(mono[right]); right += 1 }
        let start = max(0, center - half)
        while left < start { energy -= Double(mono[left]) * Double(mono[left]); left += 1 }
        dbs.append(decibels(sqrt(max(0, energy) / Double(right - left))))
    }
    let reference = percentile(dbs, dynamicsPercentile)
    let alpha = 1 - exp(-Double(step) / rate / dynamicsSmoothingSeconds)
    var gain = dynamicsTarget(dbs[0], reference: reference, range: range), gains: [Double] = []
    for db in dbs {
        gain += alpha * (dynamicsTarget(db, reference: reference, range: range) - gain)
        gains.append(gain)
    }
    return hits.map { hit in
        let position = max(0, min(Double(gains.count - 1), hit.time * rate / Double(step)))
        let i = Int(position), j = min(i + 1, gains.count - 1)
        return gains[i] + (gains[j] - gains[i]) * (position - Double(i))
    }
}

