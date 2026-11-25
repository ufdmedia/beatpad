import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

enum AnalysisMode: String { case beat, onsets }
struct AnalysisResult {
    let hits: [Hit]
    let bpm: Double?
}

func onsetEnvelope(_ kicks: [Double], _ accents: [Double], fps: Double) -> [Double] {
    let count = kicks.count
    guard count > 0 else { return [] }
    let kick90 = percentile(kicks, 0.90), accent90 = percentile(accents, 0.90)
    var env = kicks.indices.map { n in
        (kick90 > 0 ? kicks[n] / kick90 : 0) + (accent90 > 0 ? accents[n] / accent90 : 0)
    }
    var sums = [Double](repeating: 0, count: count + 1)
    for n in env.indices { sums[n + 1] = sums[n] + env[n] }
    let radius = Int((0.5 * fps).rounded())
    for n in env.indices {
        let lo = max(0, n - radius), hi = min(count - 1, n + radius)
        env[n] = max(0, env[n] - (sums[hi + 1] - sums[lo]) / Double(hi - lo + 1))
    }
    let mean = env.reduce(0, +) / Double(count)
    let std = sqrt(env.reduce(0) { $0 + pow($1 - mean, 2) } / Double(count))
    if std > 0 { for n in env.indices { env[n] /= std } }

    return env
}
// Include neighboring lags for parabolic refinement at either boundary.
func tempoSalience(_ env: [Double], fps: Double) -> (low: Int, values: [Double]) {
    let low = max(1, Int(ceil(60 * fps / 180)))
    let high = max(low, Int(floor(60 * fps / 70)))
    let values = ((low - 1)...(high + 1)).map { lag -> Double in
        guard lag > 0, lag < env.count else { return 0 }
        var sum = 0.0
        for n in 0..<(env.count - lag) { sum += env[n] * env[n + lag] }
        return sum * exp(-0.5 * pow(log2(Double(lag) / (0.5 * fps)), 2))
    }
    return (low, values)
}
func saliencePeriod(low: Int, values: [Double]) -> Double {
    let i = (1..<(values.count - 1)).max { values[$0] < values[$1] }!
    let denominator = values[i - 1] - 2 * values[i] + values[i + 1]
    let shift = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (values[i - 1] - values[i + 1]) / denominator)) : 0
    return Double(low + i - 1) + shift
}
func estimatePeriod(_ env: [Double], fps: Double) -> Double {
    let salience = tempoSalience(env, fps: fps)
    return saliencePeriod(low: salience.low, values: salience.values)
}
func trackBeats(_ env: [Double], period: Double) -> [Int] {
    let count = env.count
    guard count > 0, env.contains(where: { $0 > 0 }) else { return [] }
    // Clamp in floating point before converting, including extreme but finite --bpm values.
    let minGap = Int(max(1, min(Double(count), (period / 2).rounded())))
    let maxGap = Int(max(Double(minGap), min(Double(count), (2 * period).rounded())))
    var scores = [Double](repeating: 0, count: count)
    var back = [Int](repeating: -1, count: count)
    for t in env.indices {
        let lo = max(0, t - maxGap), hi = t - minGap
        var best = -Double.infinity
        if hi >= lo {
            for p in lo...hi {
                let candidate = scores[p] - beatTightness * pow(log(Double(t - p) / period), 2)
                if candidate > best { best = candidate; back[t] = p }
            }
        }
        scores[t] = env[t] + (back[t] >= 0 ? best : 0)
    }
    let tail = Int(max(1, min(Double(count), period.rounded())))
    var b = ((count - tail)..<count).max { scores[$0] < scores[$1] }!
    var beats: [Int] = []
    while b >= 0 { beats.append(b); b = back[b] }

    return beats.reversed()
}
func classifyBeat(_ beat: Int, kicks: [Double], accents: [Double], sr: Double, sensitivity: Double,
                  normalization: (kick: Double, accent: Double)? = nil) -> Hit? {
    let count = kicks.count, fps = sr / Double(hopSize)
    let window = Int((0.030 * fps).rounded())
    let kick95 = normalization?.kick ?? percentile(kicks, 0.95)
    let accent95 = normalization?.accent ?? percentile(accents, 0.95)
    let scale = lerp(1.4, 0.6, sensitivity)

        let range = max(0, beat - window)...min(count - 1, beat + window)
        let kickFrame = range.max { kicks[$0] < kicks[$1] }!
        let accentFrame = range.max { accents[$0] < accents[$1] }!
        let kickRatio = kick95 > 0 ? max(0, kicks[kickFrame] / kick95) : 0
        let kickStrength = min(1, kickRatio)
        let tickStrength = accent95 > 0 ? min(1, max(0, accents[accentFrame] / accent95)) : 0
        let frame: Int, kind: Kind, strength: Double
        if kickRatio >= beatKickThreshold * scale {
            frame = kickFrame; kind = .kick; strength = kickStrength
        } else if tickStrength >= beatTickThreshold * scale {
            frame = beat; kind = .accent; strength = tickStrength
        } else { return nil }
        return Hit(time: Double(frame * hopSize + fftSize / 2) / sr - onsetBias,
                        kind: kind, strength: strength)
}
func beatTrack(kicks: [Double], accents: [Double], sr: Double,
               sensitivity: Double, forcedBpm: Double?) -> AnalysisResult {
    let fps = sr / Double(hopSize)
    guard !kicks.isEmpty else { return AnalysisResult(hits: [], bpm: forcedBpm) }
    let env = onsetEnvelope(kicks, accents, fps: fps)
    let period = forcedBpm.map { 60 * fps / $0 } ?? estimatePeriod(env, fps: fps)
    guard period.isFinite, period > 0 else { usageError("--bpm is outside the supported range for this sample rate") }
    let normalization = (kick: percentile(kicks, 0.95), accent: percentile(accents, 0.95))
    let hits = trackBeats(env, period: period).compactMap {
        classifyBeat($0, kicks: kicks, accents: accents, sr: sr, sensitivity: sensitivity, normalization: normalization)
    }
    return AnalysisResult(hits: hits.sorted { $0.time < $1.time }, bpm: 60 * fps / period)
}

func analyze(_ mono: [Float], sr: Double, sensitivity: Double = 0.5,
             mode: AnalysisMode = .beat, bpm: Double? = nil) -> AnalysisResult {
    let odf = onsetFunctions(mono, sr: sr)
    if mode == .beat {
        return beatTrack(kicks: odf.kicks, accents: odf.accents, sr: sr,
                         sensitivity: sensitivity, forcedBpm: bpm)
    }
    let kickHits = peaks(odf.kicks, kind: .kick, sr: sr, sensitivity: sensitivity)
    let accentHits = peaks(odf.accents, kind: .accent, sr: sr, sensitivity: sensitivity).filter { accent in
        !kickHits.contains { abs($0.time - accent.time) <= 0.060 }
    }
    return AnalysisResult(hits: (kickHits + accentHits).sorted { $0.time < $1.time }, bpm: nil)
}

