import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Causal melody analysis (no capture or motor dependencies)

enum MelodyConfig {
    // A 32 ms window at 48 kHz offsets the added jump confirmation latency;
    // keep the hop and zero-padded FFT resolution unchanged.
    static let window = 1536, hop = 256, fft = 4096, fftLog = 12
    static let peakLow = 60.0, peakHigh = 5000.0, peakDB = -40.0
    static let low = 110.0, high = 1000.0, gridCents = 10.0
    static let harmonics = 10, harmonicDecay = 0.8, magnitudePower = 0.5
    static let kernelCents = 100.0, registerCenter = 350.0, registerSigma = 1.2
    // Persistence now rejects brief challengers, so a broader continuity prior
    // lets an ended note release promptly rather than favoring residual harmonics.
    static let candidates = 5, continuityCents = 500.0, immediateCents = 100.0
    static let octaveCents = 1200.0, octaveTolerance = 50.0, octavePenalty = 0.6
    static let smoothSeconds = 0.015, jumpFrames = 3, voiceFrames = 3, weakFrames = 4
    static let currentCents = 50.0, endedRatio = 0.4, endedFrames = 2
    static let soundingJumpFrames = 12, escapeFrames = 20
    static let smallMoveDeadbandCents = 85.0
    static let historySeconds = 10.0, medianRatio = 0.6, rmsDB = -45.0, strengthPercentile = 0.90
}
typealias MelodyFrame = (time: Double, hz: Double?, strength: Double)
func melodyNote(_ hz: Double?) -> String {
    guard let hz, hz > 0 else { return "·" }
    let midi = Int((69 + 12 * log2(hz / 440)).rounded())
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[(midi % 12 + 12) % 12])\(Int(floor(Double(midi) / 12)) - 1)"
}
final class LiveMelody {
    let sampleRate: Double
    private let fft: FFTSetup
    private var window = [Float](repeating: 0, count: MelodyConfig.window)
    private var ring = [Float](repeating: 0, count: MelodyConfig.window)
    private var input = [Float](repeating: 0, count: MelodyConfig.fft)
    private var real = [Float](repeating: 0, count: MelodyConfig.fft / 2)
    private var imag = [Float](repeating: 0, count: MelodyConfig.fft / 2)
    private var written = 0, strong = 0, weak = 0, jumpWins = 0
    private var fadedFrames = 0, rawWins = 0
    private var rawPending: Double?, smallTarget: Double?
    private var expected: Double?, pitch: Double?, pending: Double?
    private var history: [(time: Double, value: Double)] = []
    private let grid: [Double], prior: [Double]
    var onFrame: ((MelodyFrame) -> Void)?
    private(set) var current: MelodyFrame = (0, nil, 0)
    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        guard let setup = vDSP_create_fftsetup(vDSP_Length(MelodyConfig.fftLog), FFTRadix(kFFTRadix2)) else { throw CaptureError(description: "Couldn't create melody FFT") }
        fft = setup
        vDSP_hann_window(&window, vDSP_Length(MelodyConfig.window), Int32(vDSP_HANN_NORM))
        grid = (0...Int(floor(1200 * log2(MelodyConfig.high / MelodyConfig.low) / MelodyConfig.gridCents))).map {
            MelodyConfig.low * pow(2, Double($0) * MelodyConfig.gridCents / 1200)
        }
        prior = grid.map { exp(-0.5 * pow(log2($0 / MelodyConfig.registerCenter) / MelodyConfig.registerSigma, 2)) }
    }
    deinit { vDSP_destroy_fftsetup(fft) }
    func reset() {
        written = 0; strong = 0; weak = 0; jumpWins = 0
        fadedFrames = 0; rawWins = 0; rawPending = nil; smallTarget = nil
        expected = nil; pitch = nil; pending = nil; history.removeAll(keepingCapacity: true)
        ring = [Float](repeating: 0, count: MelodyConfig.window); current = (0, nil, 0)
    }
    func ingest(_ mono: UnsafeBufferPointer<Float>, firstSampleTime: Double) {
        guard !mono.isEmpty, firstSampleTime.isFinite else { return }
        if let expected, abs(firstSampleTime - expected) > liveTimestampGap { reset() }
        expected = firstSampleTime + Double(mono.count) / sampleRate
        for (i, value) in mono.enumerated() {
            ring[written % ring.count] = value; written += 1
            if written >= MelodyConfig.window, (written - MelodyConfig.window) % MelodyConfig.hop == 0 {
                analyze(time: firstSampleTime + Double(i + 1) / sampleRate)
            }
        }
    }
    private func analyze(time: Double) {
        var energy = 0.0
        for i in 0..<MelodyConfig.window {
            let value = ring[(written + i) % ring.count]
            energy += Double(value) * Double(value); input[i] = value * window[i]
        }
        for i in MelodyConfig.window..<MelodyConfig.fft { input[i] = 0 }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: MelodyConfig.fft / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(MelodyConfig.fft / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(MelodyConfig.fftLog), FFTDirection(FFT_FORWARD))
            }
        }
        imag[0] = 0
        let mags = real.indices.map { hypot(Double(real[$0]), Double(imag[$0])) / Double(2 * MelodyConfig.window) }
        let floorMag = (mags.max() ?? 0) * pow(10, MelodyConfig.peakDB / 20)
        var salience = [Double](repeating: 0, count: grid.count)
        let binHz = sampleRate / Double(MelodyConfig.fft)
        for k in 1..<(mags.count - 1) where Double(k) * binHz >= MelodyConfig.peakLow && Double(k) * binHz <= MelodyConfig.peakHigh {
            guard mags[k] > floorMag, mags[k] > mags[k-1], mags[k] >= mags[k+1] else { continue }
            let a = log(max(1e-20, mags[k-1])), b = log(max(1e-20, mags[k])), c = log(max(1e-20, mags[k+1]))
            let denominator = a - 2*b + c
            let offset = denominator == 0 ? 0 : min(0.5, max(-0.5, 0.5 * (a-c) / denominator))
            let frequency = (Double(k) + offset) * binHz
            let magnitude = exp(b - 0.25 * (a-c) * offset)
            for h in 1...MelodyConfig.harmonics {
                let center = 1200 * log2(frequency / Double(h) / MelodyConfig.low) / MelodyConfig.gridCents
                let radius = MelodyConfig.kernelCents / MelodyConfig.gridCents
                let lo = max(0, Int(ceil(center-radius))), hi = min(grid.count-1, Int(floor(center+radius)))
                if lo > hi { continue }
                let weight = pow(MelodyConfig.harmonicDecay, Double(h-1)) * pow(magnitude, MelodyConfig.magnitudePower)
                for j in lo...hi {
                    let d = (Double(j)-center) / radius
                    salience[j] += weight * pow(cos(.pi / 2 * d), 2)
                }
            }
        }
        for j in salience.indices { salience[j] *= prior[j] }
        let maxima = salience.indices.filter { j in
            salience[j] > 0 && (j == 0 || salience[j] > salience[j-1]) && (j == salience.count-1 || salience[j] >= salience[j+1])
        }.sorted { salience[$0] > salience[$1] }.prefix(MelodyConfig.candidates)
        // The raw winner measures voicing; continuity only chooses between pitch candidates.
        let best = maxima.first
        let bestValue = best.map { salience[$0] } ?? 0
        history.removeAll { time - $0.time > MelodyConfig.historySeconds }
        let recent = history.map { $0.value }
        let isStrong = bestValue > 0 && bestValue >= MelodyConfig.medianRatio * percentile(recent, 0.5)
            && decibels(sqrt(energy / Double(MelodyConfig.window))) > MelodyConfig.rmsDB
        if isStrong { strong += 1; weak = 0 } else { weak += 1; strong = 0 }
        if weak >= MelodyConfig.weakFrames {
            pitch = nil; pending = nil; jumpWins = 0
            fadedFrames = 0; rawWins = 0; rawPending = nil; smallTarget = nil
        }
        // A short salience dip does not end a voiced note. Keep counting actual
        // spectral winners through it, just as voicing retains the current pitch.
        if isStrong || pitch != nil, let best {
            var winner = best
            var escaping = false
            if let pitch {
                var currentSalience = 0.0
                for j in salience.indices where abs(1200 * log2(grid[j] / pitch)) <= MelodyConfig.currentCents {
                    currentSalience = max(currentSalience, salience[j])
                }
                fadedFrames = currentSalience < MelodyConfig.endedRatio * bestValue ? fadedFrames + 1 : 0
                // Once the old note has ended, don't let its weak residual peak
                // outweigh supported candidates solely because it is nearby.
                let supported = maxima.filter {
                    fadedFrames < MelodyConfig.endedFrames || salience[$0] >= MelodyConfig.endedRatio * bestValue
                }
                func score(_ j: Int) -> Double {
                    let delta = abs(1200 * log2(grid[j] / pitch))
                    let octave = abs(delta - MelodyConfig.octaveCents) <= MelodyConfig.octaveTolerance
                    return salience[j] * exp(-pow(delta / MelodyConfig.continuityCents, 2)) * (octave ? MelodyConfig.octavePenalty : 1)
                }
                winner = supported.max { score($0) < score($1) } ?? best
                // Anchor each run to its first raw pitch, so a moving arpeggio cannot
                // accumulate enough consecutive wins to escape the octave lock.
                if let rawPending, abs(1200 * log2(grid[best] / rawPending)) <= MelodyConfig.immediateCents {
                    rawWins += 1
                } else { rawPending = grid[best]; rawWins = 1 }
                if rawWins >= MelodyConfig.escapeFrames,
                   abs(1200 * log2(grid[best] / pitch)) > MelodyConfig.immediateCents {
                    winner = best; escaping = true
                }
            }
            let target = grid[winner]
            if let old = pitch {
                let delta = 1200 * log2(target / old)
                if abs(delta) <= MelodyConfig.immediateCents {
                    let alpha = 1 - exp(-Double(MelodyConfig.hop) / sampleRate / MelodyConfig.smoothSeconds)
                    // Ignore small pitch wobble that otherwise bypasses the
                    // large-jump persistence rule and flickers across semitones.
                    if abs(delta) > MelodyConfig.smallMoveDeadbandCents { smallTarget = target }
                    // Once a small move is accepted, finish smoothing it. Applying
                    // the deadband mid-move would leave semitone steps out of tune.
                    if let smallTarget, abs(1200 * log2(target / smallTarget)) <= MelodyConfig.currentCents {
                        pitch = old * pow(2, delta * alpha / 1200)
                        if abs(delta) <= MelodyConfig.gridCents { self.smallTarget = nil }
                    } else { smallTarget = nil }
                    pending = nil; jumpWins = 0
                } else {
                    smallTarget = nil
                    if let pending, abs(1200 * log2(target / pending)) <= MelodyConfig.immediateCents { jumpWins += 1 }
                    else { pending = target; jumpWins = 1 }
                    let required = fadedFrames >= MelodyConfig.endedFrames ? MelodyConfig.jumpFrames : MelodyConfig.soundingJumpFrames
                    if escaping || jumpWins >= required {
                        pitch = target; pending = nil; jumpWins = 0
                        fadedFrames = 0; rawWins = 0; rawPending = nil; smallTarget = nil
                    }
                }
            } else if strong >= MelodyConfig.voiceFrames { pitch = target }
        } else {
            pending = nil; jumpWins = 0; fadedFrames = 0; rawPending = nil; smallTarget = nil; rawWins = 0
        }
        if pitch != nil { history.append((time, bestValue)) }
        let strength = pitch == nil ? 0 : min(1, max(0, bestValue / max(1e-12, percentile(history.map { $0.value }, MelodyConfig.strengthPercentile))))
        current = (time, pitch, strength)
        onFrame?(current)
    }
}

struct MelodySummary {
    var frames = 0, voiced = 0, changes = 0, octaves = 0
    private var lastNote: Int?, started = 0.0, lengths: [Double] = []
    mutating func ingest(_ frame: MelodyFrame) {
        frames += 1
        let note = frame.hz.map { Int((69 + 12 * log2($0 / 440)).rounded()) }
        if note != nil { voiced += 1 }
        if note != lastNote {
            if let old = lastNote {
                lengths.append(frame.time - started)
                if let note { changes += 1; if abs(note - old) == 12 { octaves += 1 } }
            }
            started = frame.time; lastNote = note
        }
    }
    mutating func report(end: Double) {
        if lastNote != nil { lengths.append(max(0, end-started)) }
        print(String(format: "Melody summary: voiced %.2f%% · note changes %.3f/s · median note length %.3f s · octave-jump rate %.3f/s", 100 * Double(voiced) / Double(max(1, frames)), Double(changes) / max(1e-9, end), percentile(lengths, 0.5), Double(octaves) / max(1e-9, end)))
    }
}

