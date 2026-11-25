import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Predictive live tracker (audio time only)

enum LiveStatus {
    case listening, locking, locked(Double), silent
    var text: String {
        switch self {
        case .listening: return "listening…"
        case .locking: return "locking…"
        case .locked(let bpm): return String(format: "locked %.0f bpm", bpm)
        case .silent: return "silent"
        }
    }
}
struct PlannedBeat { let time: Double; let kind: Kind?; let strength: Double }
// Re-key surviving beats without changing their classification or strength.
func remapLiveGroove(_ beats: [PlannedBeat], origin: Double, period: Double) -> [Int: PlannedBeat] {
    var result: [Int: PlannedBeat] = [:]
    for beat in beats {
        let index = Int(((beat.time - origin) / period).rounded())
        if abs(beat.time - origin - Double(index) * period) <= liveGrooveSurvivalTolerance {
            result[index] = beat
        }
    }
    return result
}

// Joint pulse slope/phase search removes autocorrelation period bias before
// extrapolating. A short fixed-slope fit magnifies that bias by the age of its beats.
func fitLivePulsePeriod(_ env: [Double], times: [Double], center: Double, anchor: Double?) -> Double {
    let bins = livePulseBins, base = times[0], now = times.last!
    var bestScore = -Double.infinity, bestPeriod = center
    for step in -livePulseSteps...livePulseSteps {
        let trial = center * (1 + Double(step) * livePulseStep)
        var profile = [Double](repeating: 0, count: bins)
        for i in env.indices where times[i] <= now - liveTailPeriods * trial {
            let phase = (times[i] - base) / trial
            let bin = Int(((phase - floor(phase)) * Double(bins)).rounded()) % bins
            profile[bin] += min(livePulseClip, env[i])
        }
        let radius = max(1, min(bins / 2, Int((livePulseWidth / trial * Double(bins)).rounded())))
        for bin in 0..<bins {
            var score = 0.0
            for d in -radius...radius {
                score += profile[(bin + d + bins) % bins] * Double(radius + 1 - abs(d)) / Double(radius + 1)
            }
            let phaseTime = base + Double(bin) / Double(bins) * trial
            if let anchor {
                let distance = abs((phaseTime - anchor) - ((phaseTime - anchor) / trial).rounded() * trial)
                score *= 1 + livePulseContinuity * exp(-0.5 * pow(distance / (livePulsePhaseWidth * trial), 2))
            }
            if score > bestScore { bestScore = score; bestPeriod = trial }
        }
    }
    return bestPeriod
}

final class LiveTracker {
    let sampleRate: Double, sensitivity: Double, forcedBpm: Double?
    private let fft: OnsetWorkspace
    private var dynamics: DynamicsMeter
    private let dynamicsEnabled: Bool, dynamicsRange: Double
    var dynamicsGain: Double { dynamicsEnabled ? dynamics.gain : 1 }
    private var samples: [Float], rmsSamples: [Double]
    private var written = 0, rmsIndex = 0, rmsCount = 0
    private var energy = 0.0, recentEnergy = 0.0
    private var frames: [(time: Double, kick: Double, accent: Double)] = []
    private var expectedSampleTime: Double?
    private var lastEstimate = -Double.infinity
    private var period: Double?, anchorTime: Double?
    private var anchorIndex = 0, stableWins = 0
    private var smoothedSalience: [Double] = [], salienceLow = 0
    private var candidate: Double?, candidateWins = 0, mismatches = 0
    private var groove: [Int: PlannedBeat] = [:]
    private var lastLevelCheck = -Double.infinity, levelCandidate = 0.0, levelWins = 0
    private var rhythmConfident = false
    private var alignmentBaseline = 0.0
    private var phaseCollapseWins = 0
    private var recoveryStart: Double?
    private(set) var status: LiveStatus = .listening
    private(set) var relocks = 0, correctionCount = 0
    private(set) var correctionTotal = 0.0
    var rms: Double { sqrt(max(0, energy) / Double(max(1, rmsCount))) }
    var beatPeriod: Double { period ?? 0.5 }
    init(sampleRate: Double, sensitivity: Double, forcedBpm: Double?, dynamicsEnabled: Bool = true, dynamicsRange: Double = 15) throws {
        self.dynamicsEnabled = dynamicsEnabled; self.dynamicsRange = dynamicsRange
        dynamics = DynamicsMeter(rate: sampleRate, range: dynamicsRange)
        self.sampleRate = sampleRate; self.sensitivity = sensitivity; self.forcedBpm = forcedBpm
        do { try Self.validateTempo(forcedBpm, sampleRate: sampleRate) }
        catch { usageError(String(describing: error)) }
        fft = try OnsetWorkspace(sr: sampleRate)
        samples = [Float](repeating: 0, count: Int(ceil(liveHistorySeconds * sampleRate)))
        rmsSamples = [Double](repeating: 0, count: Int(ceil(sampleRate)))
    }
    static func validateTempo(_ forcedBpm: Double?, sampleRate: Double) throws {
        if let forcedBpm {
            let framePeriod = 60 * sampleRate / Double(hopSize) / forcedBpm
            guard framePeriod.isFinite, framePeriod >= 1, framePeriod < Double(Int.max / 64) else {
                throw CaptureError(description: "--bpm is outside the supported range for this sample rate")
            }
        }
    }
    // Called with the monotonic host clock, never the output-latency-adjusted clock.
    func audioIsFresh(at time: Double) -> Bool {
        guard let newestSampleTime else { return false }
        let age = time - newestSampleTime
        if age > 2, !staleReset {
            reset(); status = .listening; staleReset = true
            expectedSampleTime = nil
            dynamics = DynamicsMeter(rate: sampleRate, range: dynamicsRange)
            rmsSamples = [Double](repeating: 0, count: rmsSamples.count)
            rmsIndex = 0; rmsCount = 0; energy = 0; recentEnergy = 0
        }
        return age <= 0.5
    }
    private var newestSampleTime: Double?
    private var staleReset = false
    private(set) var resetGeneration = 0
    private func reset() {
        resetGeneration += 1
        frames.removeAll(keepingCapacity: true); groove.removeAll(keepingCapacity: true)
        period = nil; anchorTime = nil; anchorIndex = 0; stableWins = 0; rhythmConfident = false
        smoothedSalience.removeAll(keepingCapacity: true); salienceLow = 0
        candidate = nil; candidateWins = 0; mismatches = 0
        lastEstimate = -Double.infinity; lastLevelCheck = -Double.infinity; levelWins = 0
        alignmentBaseline = 0; phaseCollapseWins = 0; recoveryStart = nil
        written = 0; fft.reset()
    }
    func ingest(_ mono: UnsafeBufferPointer<Float>, firstSampleTime: Double) {
        guard !mono.isEmpty, firstSampleTime.isFinite else { return }
        newestSampleTime = firstSampleTime + Double(mono.count - 1) / sampleRate
        staleReset = false
        if let expectedSampleTime, abs(firstSampleTime - expectedSampleTime) > liveTimestampGap {
            reset(); status = .listening
            dynamics = DynamicsMeter(rate: sampleRate, range: dynamicsRange)
            rmsSamples = [Double](repeating: 0, count: rmsSamples.count)
            rmsIndex = 0; rmsCount = 0; energy = 0; recentEnergy = 0
        }
        if dynamicsEnabled { dynamics.ingest(mono) }
        expectedSampleTime = firstSampleTime + Double(mono.count) / sampleRate
        for (i, value) in mono.enumerated() {
            let square = Double(value) * Double(value)
            let recentCount = min(rmsSamples.count, max(1, Int(sampleRate * 0.020)))
            let outgoing = (rmsIndex - recentCount + rmsSamples.count) % rmsSamples.count
            recentEnergy += square - rmsSamples[outgoing]
            energy += square - rmsSamples[rmsIndex]; rmsSamples[rmsIndex] = square
            rmsIndex = (rmsIndex + 1) % rmsSamples.count; rmsCount = min(rmsCount + 1, rmsSamples.count)
            if rms < pow(10, -55.0 / 20) {
                if case .silent = status {} else { reset(); status = .silent }
                continue
            }
            if case .silent = status { status = .listening }
            samples[written % samples.count] = value; written += 1
            guard written >= fftSize, (written - fftSize) % hopSize == 0 else { continue }
            let start = written - fftSize
            let (kick, accent) = fft.onsetFrame { self.samples[(start + $0) % self.samples.count] }
            let time = firstSampleTime + Double(i + 1 - fftSize / 2) / sampleRate - onsetBias
            frames.append((time, kick, accent))
            while let first = frames.first, time - first.time > liveHistorySeconds { frames.removeFirst() }
            if let first = frames.first, time - first.time >= liveStartSeconds, time - lastEstimate >= liveEstimateInterval {
                lastEstimate = time; reestimate(at: time)
            }
        }
    }
    private func alignment(at time: Double, period: Double, anchor: Double) -> (recent: Double, full: Double, changed: Bool) {
        let recent = frames.filter { time - $0.time <= liveAlignmentWindow }
        let fps = sampleRate / Double(hopSize)
        let env = onsetEnvelope(recent.map { $0.kick }, recent.map { $0.accent }, fps: fps)
        let start = recent.firstIndex { time - $0.time <= liveAlignmentRecent } ?? 0
        var total = 0.0, aligned = 0.0, all = 0.0, allAligned = 0.0
        for i in recent.indices {
            let strength = min(liveAlignmentClip, env[i]) * min(liveAlignmentClip, env[i])
            let distance = abs((recent[i].time - anchor) - ((recent[i].time - anchor) / period).rounded() * period)
            all += strength
            if distance <= liveAlignmentWidth { allAligned += strength }
            if i >= start {
                total += strength
                if distance <= liveAlignmentWidth { aligned += strength }
            }
        }
        let values = Array(env[start...])
        let power = max(1e-12, values.reduce(0) { $0 + $1 * $1 })
        func correlation(_ lag: Int) -> Double {
            guard lag > 0, lag < values.count else { return 0 }
            var sum = 0.0
            for i in lag..<values.count { sum += values[i] * values[i-lag] }
            return sum / power
        }
        let lags = Int(60*fps/180)...Int(60*fps/70)
        let best = lags.max { correlation($0) < correlation($1) }!
        let old = Int((period*fps).rounded())
        let oldScore = (max(1,old-liveAlignmentLagRadius)...max(1,old+liveAlignmentLagRadius)).map(correlation).max() ?? 0
        let newPeriod = Double(best)/fps
        // Short fills often emphasize half, triplet, or dotted subdivisions.
        // Keep the metrical level unless recent rhythm truly changes.
        let alias = [1.0, 0.5, 2.0, 1.5, 2.0/3].contains { abs(newPeriod/(period*$0)-1) <= liveAlignmentAliasTolerance } || [0.75, 4.0/3].contains { abs(newPeriod/(period*$0)-1) <= liveAlignmentTupletTolerance }
        var phaseScore = 0.0
        for bin in 0..<liveAlignmentPhaseBins {
            let phase = anchor + Double(bin)*period/Double(liveAlignmentPhaseBins)
            var mass = 0.0
            for i in start..<recent.count {
                let d = recent[i].time-phase
                if abs(d-(d/period).rounded()*period) <= liveAlignmentWidth {
                    mass += min(liveAlignmentClip, env[i])*min(liveAlignmentClip, env[i])
                }
            }
            phaseScore = max(phaseScore,mass/max(1e-12,total))
        }
        // Energy loss alone is insufficient: require a repeating new rhythm,
        // or two consistent estimates of strong energy at a different phase.
        let tempoChanged = !alias && correlation(best) >= liveAlignmentNewCorrelation && oldScore < liveAlignmentOldCorrelation
        let phaseChanged = abs(newPeriod/period-1) <= liveTempoTolerance && oldScore >= liveAlignmentNewCorrelation && phaseScore >= liveAlignmentPhaseFloor && aligned/max(1e-12,total) < liveAlignmentPhaseRatio*phaseScore && alignmentBaseline >= liveAlignmentPhaseFloor
        phaseCollapseWins = phaseChanged ? phaseCollapseWins + 1 : 0
        let changed = (tempoChanged || phaseCollapseWins >= liveAlignmentPhaseWins) && total >= liveAlignmentMassFloor * all
        return (aligned/max(1e-12,total), allAligned/max(1e-12,all), changed)
    }
    private func reestimate(at time: Double) {
        if case .locked = status, let p = period, let anchor = anchorTime {
            let (recent, full, changed) = alignment(at: time, period: p, anchor: anchor)
            if changed && full >= liveAlignmentContextFloor && recent < liveAlignmentFloor && recent < liveAlignmentRatio * alignmentBaseline {
                status = .locking; rhythmConfident = false; relocks += 1
                period = nil; anchorTime = nil; anchorIndex = 0; stableWins = 0
                smoothedSalience.removeAll(); salienceLow = 0; groove.removeAll()
                candidate = nil; candidateWins = 0; mismatches = 0
                levelWins = 0; lastLevelCheck = -.infinity; alignmentBaseline = 0; phaseCollapseWins = 0
                // Discard long history, retaining only the evidence of the collapse.
                // The audio clock and STFT remain continuous across a hard cut.
                recoveryStart = time - liveAlignmentRecent
                frames.removeAll { $0.time < recoveryStart! }
                return
            }
            alignmentBaseline = max(full, alignmentBaseline * liveAlignmentDecay)
        }
        if let recoveryStart, time - recoveryStart < liveStartSeconds { return }
        // Rebuild salience/phase/groove from a short window first. Once warm,
        // accumulated post-change history can lengthen toward the full window.
        let windowSeconds = recoveryStart != nil && time - recoveryStart! < liveMemoryWarmupSeconds ? liveReacquireWindow : liveWindowSeconds
        let window = frames.filter { time - $0.time <= windowSeconds }
        let kicks = window.map { $0.kick }, accents = window.map { $0.accent }
        let fps = sampleRate / Double(hopSize)
        let env = onsetEnvelope(kicks, accents, fps: fps)
        let salience = tempoSalience(env, fps: fps)
        if salience.low != salienceLow || smoothedSalience.count != salience.values.count {
            smoothedSalience = salience.values; salienceLow = salience.low
        } else {
            for i in smoothedSalience.indices {
                let memory: Double
                if case .locked = status, time - window[0].time >= liveMemoryWarmupSeconds { memory = liveLockedSalienceMemory } else { memory = liveSalienceMemory }
                smoothedSalience[i] = memory * smoothedSalience[i] + (1 - memory) * salience.values[i]
            }
        }
        // Compare metrical levels without the continuity bonus. Require sustained
        // evidence so a fill cannot halve/double the grid.
        if forcedBpm == nil, case .locked = status, let old = period,
           time - lastLevelCheck >= (time - window[0].time < liveMemoryWarmupSeconds ? liveEarlyLevelInterval : liveLevelInterval) {
            lastLevelCheck = time
            func score(_ p: Double) -> Double {
                let center = Int((p * fps).rounded()) - salienceLow + 1
                guard center >= 1, center < smoothedSalience.count - 1 else { return 0 }
                return smoothedSalience[max(1, center - 1)...min(smoothedSalience.count - 2, center + 1)].max() ?? 0
            }
            let alternatives = [0.5, 2.0, 2.0 / 3, 1.5]
            let ratio = alternatives.max { score(old * $0) < score(old * $1) }!
            if score(old * ratio) > liveLevelMargin * score(old) {
                if ratio == levelCandidate { levelWins += 1 } else { levelCandidate = ratio; levelWins = 1 }
                if levelWins >= liveLevelWins {
                    let newPeriod = old * ratio
                    if let anchor = anchorTime {
                        var origin = anchor
                        if ratio > 1 {
                            // Pick the subset supported by the strongest kicks.
                            let options = ratio == 2 ? [anchor, anchor + old] : [anchor, anchor + old, anchor + 2 * old]
                            origin = options.max { a, b in
                                func strength(_ t: Double) -> Double {
                                    window.reduce(0) { sum, f in
                                        let distance = abs((f.time - t) - ((f.time - t) / newPeriod).rounded() * newPeriod)
                                        return sum + (distance <= liveLevelKickWindow ? f.kick : 0)
                                    }
                                }
                                return strength(a) < strength(b)
                            }!
                        }
                        groove = remapLiveGroove(Array(groove.values), origin: origin, period: newPeriod)
                        anchorTime = origin; anchorIndex = 0
                    }
                    alignmentBaseline = 0; phaseCollapseWins = 0
                    period = newPeriod; candidate = nil; candidateWins = 0
                    levelWins = 0
                }
            } else { levelWins = 0 }
        }
        var weighted = smoothedSalience
        if let period {
            for i in weighted.indices {
                let lag = Double(salienceLow + i - 1)
                if lag > 0 { weighted[i] *= liveContinuityFloor + exp(-0.5 * pow(log2(lag / (period * fps)) / liveContinuityWidth, 2)) }
            }
        }
        let proposed = forcedBpm.map { 60 / $0 } ?? (saliencePeriod(low: salienceLow, values: weighted) / fps)
        guard proposed.isFinite, proposed > 0 else { return }
        if let locked = period {
            let alias = [2.0, 0.5, 1.5, 2.0 / 3].contains { abs(proposed / (locked * $0) - 1) <= liveTempoTolerance }
            let adjusted = alias ? locked : proposed
            if abs(adjusted / locked - 1) <= liveTempoTolerance {
                period = (1 - liveTempoGain) * locked + liveTempoGain * adjusted
                candidate = nil; candidateWins = 0
            } else {
                if let candidate, abs(proposed / candidate - 1) <= liveTempoTolerance { candidateWins += 1 }
                else { candidate = proposed; candidateWins = 1 }
                if candidateWins >= liveTempoWins {
                    alignmentBaseline = 0; phaseCollapseWins = 0
                    period = proposed; candidate = nil; candidateWins = 0
                    anchorTime = nil; stableWins = 0; mismatches = 0
                    status = .locking; groove.removeAll(); relocks += 1
                }
            }
        } else { period = proposed; status = .locking }
        var p = period!
        let beats = trackBeats(env, period: p * fps).filter { window[$0].time <= time - liveTailPeriods * p }
        guard beats.count >= 4 else { return }
        // Fit period independently of short DP phase changes.
        let near = (1..<(smoothedSalience.count - 1)).filter { abs(Double(salienceLow + $0 - 1) / (p * fps) - 1) < liveFitPeriodTolerance }
        var fitCenter = p
        if forcedBpm == nil, let peak = near.max(by: { smoothedSalience[$0] < smoothedSalience[$1] }) {
            let denominator = smoothedSalience[peak - 1] - 2 * smoothedSalience[peak] + smoothedSalience[peak + 1]
            let shift = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (smoothedSalience[peak - 1] - smoothedSalience[peak + 1]) / denominator)) : 0
            fitCenter = (Double(salienceLow + peak - 1) + shift) / fps
        }
        var phaseAnchor: Double?
        if case .locked = status { phaseAnchor = anchorTime }
        p = forcedBpm == nil ? fitLivePulsePeriod(env, times: window.map { $0.time }, center: fitCenter, anchor: phaseAnchor) : p
        period = p
        let lag = Int((p * fps).rounded())
        let confidenceEnv = env
        let power = confidenceEnv.reduce(0) { $0 + $1 * $1 }
        var correlation = 0.0
        for offset in max(1, lag - 1)...max(1, lag + 1) where offset < confidenceEnv.count {
            var sum = 0.0
            for i in 0..<(confidenceEnv.count - offset) { sum += confidenceEnv[i] * confidenceEnv[i + offset] }
            correlation = max(correlation, sum / max(1e-12, power))
        }
        rhythmConfident = correlation >= liveMinimumCorrelation
        let recent = Array(beats.suffix(liveFitBeats)).map { window[$0].time }
        let phaseOrigin = recent.last!
        let intercept = percentile(recent.map { $0 - (($0 - phaseOrigin) / p).rounded() * p }, 0.5)
        if let current = anchorTime {
            let aligned = intercept + ((current - intercept) / p).rounded() * p
            let delta = aligned - current
            correctionTotal += abs(delta); correctionCount += 1
            if abs(delta) <= livePhaseTolerance * p {
                anchorTime = current + livePhaseGain * delta; mismatches = 0; stableWins += 1
            } else {
                stableWins = 0; mismatches += 1
                if mismatches >= livePhaseMismatches {
                    alignmentBaseline = 0; phaseCollapseWins = 0
                    anchorTime = aligned; mismatches = 0; relocks += 1
                    status = .locking; groove.removeAll()
                }
            }
        } else { anchorTime = intercept; stableWins = 0 }
        if stableWins >= liveLockWins { status = .locked(60 / p) }
        else if case .locked = status { status = .locked(60 / p) }
        // Keep the phase reference near now so tempo updates cannot accumulate
        // an ever-growing offset from the beginning of the track.
        let advance = max(0, Int(floor((time - anchorTime!) / p)))
        anchorTime! += Double(advance) * p; anchorIndex += advance
        let origin = anchorTime!
        let normalization = (kick: percentile(kicks, 0.95), accent: percentile(accents, 0.95))
        for beat in beats {
            let index = anchorIndex + Int(((window[beat].time - origin) / p).rounded())
            let hit = classifyBeat(beat, kicks: kicks, accents: accents, sr: sampleRate, sensitivity: sensitivity, normalization: normalization)
            groove[index] = PlannedBeat(time: window[beat].time, kind: hit?.kind, strength: hit?.strength ?? 0)
        }
        groove = groove.filter { $0.key >= anchorIndex - 24 }
    }
    func plan(after time: Double) -> PlannedBeat? {
        guard rhythmConfident, case .locked = status, let anchorTime, let period, time.isFinite,
              sqrt(max(0, recentEnergy) / Double(max(1, Int(sampleRate * 0.020)))) >= pow(10, -55.0 / 20) else { return nil }
        let k = Int(floor((time - anchorTime) / period)) + 1
        let index = anchorIndex + k
        let remembered = groove[index - 4] ?? groove[index - 2]
        return PlannedBeat(time: anchorTime + Double(k) * period,
                           kind: remembered?.kind ?? (remembered == nil ? .kick : nil),
                           strength: remembered?.strength ?? 0.6)
    }
}
