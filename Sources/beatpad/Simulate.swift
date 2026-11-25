import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// A commit occupies one predicted beat interval. Union those intervals, clipped
// at the splice and first validated recovery, so silence never counts as wrong.
struct MeasuredCommit { let time: Double; let period: Double }
func spliceRecovery(_ commits: [MeasuredCommit], reference: [Double], period: Double,
                    splice: Double, end: Double) -> (wrong: Double, recovery: Double) {
    let after = commits.filter { $0.time >= splice && $0.time < end }
    func correct(_ c: MeasuredCommit) -> Bool {
        abs(period / c.period - 1) <= 0.04 && reference.contains { abs($0 - c.time) <= 0.030 }
    }
    // Report the beginning of a complete, subsequently validated four-second
    // window. Require 75% beat coverage as well, ruling out empty/sparse windows.
    let recovered = after.first { c in
        guard c.time + 4 <= end else { return false }
        let window = after.filter { $0.time >= c.time && $0.time < c.time + 4 }
        return Double(window.count) >= 0.75 * 4 / period &&
            Double(window.filter(correct).count) / Double(window.count) >= 0.90
    }?.time ?? .infinity
    var wrong = 0.0, coveredUntil = splice
    for c in after where c.time < recovered && !correct(c) {
        let start = max(splice, max(coveredUntil, c.time))
        let stop = min(end, min(recovered, c.time + c.period))
        wrong += max(0, stop - start); coveredUntil = max(coveredUntil, stop)
    }
    return (wrong, recovered - splice)
}

// Each splice segment gets its own offline tempo and DP grid. The tracker never
// receives the splice time or either reference; those are measurement-only.
func simulateLive(_ audio: LoadedAudio, jitterUS: Double, spliceAt: Double? = nil, dynamicsEnabled: Bool = true, dynamicsRange: Double = 15, melodyEnabled: Bool = false) {
    if let spliceAt, spliceAt <= 0 || spliceAt >= audio.duration {
        usageError("--splice-at must lie inside the audio duration")
    }
    let fps = audio.sr / Double(hopSize)
    func grid(_ samples: [Float], offset: Double) -> (period: Double, times: [Double]) {
        let odf = onsetFunctions(samples, sr: audio.sr)
        let env = onsetEnvelope(odf.kicks, odf.accents, fps: fps)
        let period = estimatePeriod(env, fps: fps) / fps
        return (period, trackBeats(env, period: period * fps).map {
            offset + Double($0 * hopSize + fftSize / 2) / audio.sr - onsetBias
        })
    }
    let split = spliceAt.map { Int(($0 * audio.sr).rounded()) } ?? audio.mono.count
    guard split >= fftSize, audio.mono.count - split >= (spliceAt == nil ? 0 : fftSize) else {
        usageError("each reference segment needs at least one FFT window")
    }
    let first = grid(Array(audio.mono[..<split]), offset: 0)
    let second = spliceAt.map { _ in grid(Array(audio.mono[split...]), offset: Double(split) / audio.sr) }
    let filePeriod = second?.period ?? first.period
    let evaluationStart = (spliceAt ?? 0) + 10
    let reference = (second?.times ?? first.times).filter { $0 >= evaluationStart }
    let tracker: LiveTracker
    do { tracker = try LiveTracker(sampleRate: audio.sr, sensitivity: 0.5, forcedBpm: nil, dynamicsEnabled: dynamicsEnabled, dynamicsRange: dynamicsRange) }
    catch { fail(String(describing: error)) }
    let melody: LiveMelody?
    do { melody = try melodyEnabled ? LiveMelody(sampleRate: audio.sr) : nil }
    catch { fail(String(describing: error)) }
    var melodyStats = MelodySummary(), nextMelodyLine = 0.5
    melody?.onFrame = { melodyStats.ingest($0) }
    var dynamicsWindows: [Int: [Double]] = [:]
    var rng = SeededRandom(), commits: [Double] = [], measured: [MeasuredCommit] = []
    var last = -Double.infinity, lockTime: Double?, wasLocked = false, flips = 0, nextLine = 2.0
    var lockedSeconds = 0.0, agreedSeconds = 0.0, finalBPM = 0.0
    for start in stride(from: 0, to: audio.mono.count, by: 512) {
        let end = min(start + 512, audio.mono.count), t = Double(end) / audio.sr
        let jitter = rng.noise() * jitterUS * 1e-6
        audio.mono.withUnsafeBufferPointer {
            let generation = tracker.resetGeneration
            let chunk = UnsafeBufferPointer(rebasing: $0[start..<end])
            tracker.ingest(chunk, firstSampleTime: Double(start) / audio.sr + jitter)
            if tracker.resetGeneration != generation { melody?.reset() }
            melody?.ingest(chunk, firstSampleTime: Double(start) / audio.sr + jitter)
        }
        if let melody {
            if t >= nextMelodyLine {
                if let hz = melody.current.hz {
                    print(String(format: "mel t=%.1f %@ %.0fHz s=%.2f", nextMelodyLine, melodyNote(hz), hz, melody.current.strength))
                } else { print(String(format: "mel t=%.1f -", nextMelodyLine)) }
                nextMelodyLine += 0.5
            }
        }
        var locked = false, bpm = 0.0
        if case .locked(let value) = tracker.status { locked = true; bpm = value; if lockTime == nil { lockTime = t } }
        if locked {
            finalBPM = bpm
            let dt = max(0, t - max(15, Double(start) / audio.sr))
            lockedSeconds += dt
            let referencePeriod = t < (spliceAt ?? .infinity) ? first.period : filePeriod
            if abs(bpm / (60 / referencePeriod) - 1) <= 0.04 { agreedSeconds += dt }
        }
        if wasLocked && !locked { flips += 1 }; wasLocked = locked
        if let beat = tracker.plan(after: max(last + 0.25 * tracker.beatPeriod, t - 0.020)), beat.time <= t + 0.020 {
            last = beat.time
            if beat.kind != nil {
                dynamicsWindows[Int(t / 10), default: []].append(tracker.dynamicsGain)
                measured.append(MeasuredCommit(time: beat.time, period: tracker.beatPeriod))
                if beat.time >= evaluationStart { commits.append(beat.time) }
            }
        }
        if t >= nextLine {
            print(String(format: "t=%.1f status=%@ bpm=%.1f", nextLine, locked ? "locked" : tracker.status.text, bpm))
            nextLine += 2
        }
    }
    if melody != nil { melodyStats.report(end: audio.duration) }
    for window in 0..<Int(ceil(audio.duration / 10)) {
        let gains = dynamicsWindows[window] ?? []
        if gains.isEmpty { print("dyn t=\(window * 10)-\((window + 1) * 10) mean=n/a") }
        else { print(String(format: "dyn t=%d-%d mean=%.2f", window * 10, (window + 1) * 10, gains.reduce(0, +) / Double(gains.count))) }
    }
    let errors = commits.map { t in reference.map { abs($0 - t) }.min() ?? .infinity }
    let recalled = reference.filter { t in commits.contains { abs($0 - t) <= 0.030 } }.count
    let precise = errors.filter { $0 <= 0.030 }.count
    let mean = errors.isEmpty ? Double.infinity : errors.reduce(0, +) / Double(errors.count)
    print(String(format: "relocks %d · lock after %.3f s", tracker.relocks, lockTime ?? .infinity))
    print(String(format: "evaluation: recall %.2f %% · precision %.2f %% · mean |error| %.3f ms · p90 |error| %.3f ms · status flips %d", 100 * Double(recalled) / Double(max(1, reference.count)), 100 * Double(precise) / Double(max(1, commits.count)), mean * 1000, errors.isEmpty ? .infinity : percentile(errors, 0.90) * 1000, flips))
    var spliceResult = ""
    if let spliceAt, let second {
        let result = spliceRecovery(measured, reference: second.times, period: second.period, splice: spliceAt, end: audio.duration)
        print(String(format: "splice at %.3f s: %.3f → %.3f bpm · wrong-thump %.3f s · re-acquire %.3f s · evaluation from %.3f s", spliceAt, 60 / first.period, 60 / second.period, result.wrong, result.recovery, evaluationStart))
        spliceResult = String(format: " first_bpm=%.3f wrong_s=%.3f reacquire_s=%.3f", 60 / first.period, result.wrong, result.recovery)
    }
    print(String(format: "RESULT file_bpm=%.3f live_bpm=%.3f agreement=%.2f relocks=%d lock_s=%.3f flips=%d recall=%.2f precision=%.2f mean_ms=%.3f p90_ms=%.3f locked_s=%.3f", 60 / filePeriod, finalBPM, lockedSeconds > 0 ? 100 * agreedSeconds / lockedSeconds : 0, tracker.relocks, lockTime ?? .infinity, flips, 100 * Double(recalled) / Double(max(1, reference.count)), 100 * Double(precise) / Double(max(1, commits.count)), mean * 1000, errors.isEmpty ? .infinity : percentile(errors, 0.90) * 1000, lockedSeconds) + spliceResult)
}

