import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Repeatable synthetic audio

struct SeededRandom {
    var seed: UInt64 = 0xBEA7_2026
    mutating func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 32) / Double(UInt32.max) * 2 - 1
    }
}
func sweep(_ t: Double, duration: Double) -> Double {
    sin(2 * .pi * (150 * t - 50 * t * t / duration))
}
func testTrack(beatScenario: Bool = false, sr: Double = 44100, duration: Double = 12, bpm: Double = 120, firstBeat: Double = 0.5) -> (samples: [Float], kicks: [Double], snares: [Double], hats: [Double]) {
    let period = 60 / bpm
    var rng = SeededRandom()
    var samples = [Float](repeating: 0, count: Int(duration * sr))
    let kicks = beatScenario ? stride(from: firstBeat, to: duration, by: 2 * period).map { $0 } : (1..<24).map { Double($0) * 0.5 }
    let snares = beatScenario ? stride(from: firstBeat + period, to: duration, by: 2 * period).map { $0 } : (1..<12).map { Double($0) }
    let hats = stride(from: beatScenario ? firstBeat : 0.625, to: duration, by: period / 2).map { $0 }
    var phase = 0.0
    for i in samples.indices {
        let t = Double(i) / sr
        let pitch = max(0, Int(floor((t - 0.5) / 2))) % 2 == 0 ? 55.0 : 65.4
        samples[i] = Float((beatScenario ? 0 : 0.2 * sin(phase)) + 0.01 * rng.noise())
        phase += 2 * .pi * pitch / sr
        phase.formTruncatingRemainder(dividingBy: 2 * .pi)
    }
    func add(_ start: Double, _ duration: Double, _ sample: (Double) -> Double) {
        let first = Int((start * sr).rounded())
        for i in 0..<Int(duration * sr) where first + i < samples.count {
            samples[first + i] += Float(sample(Double(i) / sr))
        }
    }
    for start in kicks { add(start, 0.120) { 0.8 * sweep($0, duration: 0.120) * exp(-$0 / 0.040) } }
    for start in snares {
        add(start, 0.080) { 0.5 * rng.noise() * exp(-$0 / 0.020) }
        add(start, 0.060) { 0.3 * sin(2 * .pi * 200 * $0) }
    }
    for start in hats {
        var previous = rng.noise()
        add(start, 0.030) { t in
            let next = rng.noise(), difference = next - previous
            previous = next
            return 0.15 * difference * exp(-t / 0.008)
        }
    }
    if beatScenario {
        for start in stride(from: firstBeat + period / 2, to: duration, by: period) {
            add(start, 0.150) { 0.5 * sin(2 * .pi * 55 * $0) * exp(-$0 / 0.050) }
        }
    }
    return (samples, kicks, snares, hats)
}
func pcmBuffer(_ samples: [Float], sr: Double) -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = buffer.floatChannelData?[0] else { fail("Couldn't allocate an audio buffer.") }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
    return buffer
}
func writeWAV(_ samples: [Float], sr: Double, url: URL) {
    let buffer = pcmBuffer(samples, sr: sr)
    do {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    } catch { fail("Couldn't write test WAV: \(error.localizedDescription)") }
}
func melodySelftest() -> [Bool] {
    print("Scenario I (predominant melody, 48 kHz, 512-sample chunks, ±200 µs jitter)")
    let sr = 48000.0, duration = 30.0, leadLevel = 0.5
    var audio = testTrack(beatScenario: true, sr: sr, duration: duration).samples
    var truth: [(start: Double, end: Double, hz: Double?)] = []
    var time = 0.1, index = 0, midi = 55, direction = 1
    truth.append((0, time, nil))
    while time < duration {
        if [10, 25, 40, 55].contains(index) {
            truth.append((time, min(duration, time + 0.4), nil)); time += 0.4
        }
        if index == 18 || index == 45 { midi += midi <= 67 ? 12 : -12 }
        else if index > 0 {
            if midi >= 79 { direction = -1 }; if midi <= 55 { direction = 1 }
            midi += direction * 2
        }
        var end = min(duration, time + [0.2, 0.3, 0.4, 0.5, 0.6][index % 5])
        // Extend the penultimate note instead of leaving a final note below 200 ms.
        if duration - end < 0.2 { end = duration }
        if end <= time { break }
        let hz = 440 * pow(2, Double(midi-69)/12)
        truth.append((time, end, hz)); time = end; index += 1
    }
    let competingStart = duration / 2, arpeggioSeconds = 0.080
    let arpeggioMIDI = [76, 79, 83, 79] // competing upper-register harmonic instrument
    var segment = 0
    for i in audio.indices {
        let t = Double(i) / sr
        while segment + 1 < truth.count && t >= truth[segment].end { segment += 1 }
        let note = truth[segment]
        if let hz = note.hz, t >= note.start {
            let envelope = min(1, (t-note.start)/0.002, (note.end-t)/0.002)
            var value = 0.0
            for h in 1...8 { value += sin(2 * .pi * hz * Double(h) * (t-note.start)) / Double(h) }
            audio[i] += Float(leadLevel * max(0, envelope) * value)
        }
        // The arrangement shares the lead's explicit rests, preserving the
        // existing test of unvoicing during silence in the foreground.
        if t >= competingStart, note.hz != nil {
            let elapsed = t - competingStart
            let noteIndex = Int(elapsed / arpeggioSeconds)
            let local = elapsed - Double(noteIndex) * arpeggioSeconds
            let hz = 440 * pow(2, Double(arpeggioMIDI[noteIndex % arpeggioMIDI.count] - 69) / 12)
            let envelope = max(0, min(1, local / 0.002, (arpeggioSeconds - local) / 0.002))
            var value = 0.0
            for h in 1...8 { value += sin(2 * .pi * hz * Double(h) * local) / Double(h) }
            audio[i] += Float(leadLevel * pow(10, -3.0 / 20) * envelope * value)
        }
        // A sustained C-major pad at -18 dB per sine partial relative to the lead.
        for hz in [130.8128, 164.8138, 195.9977] {
            audio[i] += Float(leadLevel * pow(10, -18.0/20) * sin(2 * .pi * hz * t))
        }
    }
    let melody: LiveMelody
    do { melody = try LiveMelody(sampleRate: sr) }
    catch { fail(String(describing: error)) }
    var evaluated = 0, correct = 0, recalled = 0, octaveErrors = 0, rests = 0, restVoiced = 0
    var competingEvaluated = 0, competingCorrect = 0, competingChanges = 0
    var competingLastNote: String?
    var onsetFirst: [Int: Double] = [:], delivery = 0.0, rng = SeededRandom()
    melody.onFrame = { frame in
        guard let j = truth.firstIndex(where: { frame.time >= $0.start && frame.time < $0.end }) else { return }
        let note = truth[j]
        if frame.time >= competingStart {
            let output = frame.hz.map { melodyNote($0) }
            if let output, let previous = competingLastNote, output != previous { competingChanges += 1 }
            competingLastNote = output
        }
        if let hz = note.hz {
            let cents = frame.hz.map { abs(1200 * log2($0 / hz)) } ?? .infinity
            if cents <= 50, onsetFirst[j] == nil { onsetFirst[j] = delivery - note.start }
            if frame.time >= note.start + 0.060 {
                evaluated += 1
                if frame.time >= competingStart {
                    competingEvaluated += 1
                    if cents <= 50 { competingCorrect += 1 }
                }
                if frame.hz != nil { recalled += 1 }
                if cents <= 50 { correct += 1 }
                if abs(cents - 1200) <= 50 { octaveErrors += 1 }
            }
        } else if frame.time >= note.start + 0.060 {
            rests += 1; if frame.hz != nil { restVoiced += 1 }
        }
    }
    for start in stride(from: 0, to: audio.count, by: 512) {
        let end = min(audio.count, start+512)
        delivery = Double(end)/sr
        let jitter = rng.noise()*200e-6
        audio.withUnsafeBufferPointer { melody.ingest(UnsafeBufferPointer(rebasing: $0[start..<end]), firstSampleTime: Double(start)/sr+jitter) }
    }
    let accuracy = Double(correct)/Double(max(1,evaluated)), recall = Double(recalled)/Double(max(1,evaluated))
    let octave = Double(octaveErrors)/Double(max(1,evaluated)), falseVoice = Double(restVoiced)/Double(max(1,rests))
    let notes = truth.indices.filter { truth[$0].hz != nil }
    // Missed notes count their full duration, rather than disappearing from the mean.
    let lag = notes.map { onsetFirst[$0] ?? (truth[$0].end-truth[$0].start) }.reduce(0,+)/Double(notes.count)
    var checks = [accuracy >= 0.85, octave <= 0.05, recall >= 0.85, falseVoice <= 0.15, lag <= 0.040]
    print(String(format: "%@ pitch within ±50 cents: %.2f%% (minimum 85%%)", checks[0] ? "PASS":"FAIL", accuracy*100))
    print(String(format: "%@ octave errors: %.2f%% (maximum 5%%)", checks[1] ? "PASS":"FAIL", octave*100))
    print(String(format: "%@ voicing recall: %.2f%% (minimum 85%%)", checks[2] ? "PASS":"FAIL", recall*100))
    print(String(format: "%@ voiced during rests after 60 ms: %.2f%% (maximum 15%%)", checks[3] ? "PASS":"FAIL", falseVoice*100))
    print(String(format: "%@ mean onset lag: %.3f ms (maximum 40 ms; %d/%d notes found)", checks[4] ? "PASS":"FAIL", lag*1000, onsetFirst.count, notes.count))
    let leadChanges = zip(truth, truth.dropFirst()).filter {
        $0.1.start >= competingStart && $0.0.hz != nil && $0.1.hz != nil && $0.0.hz != $0.1.hz
    }.count
    let competingAccuracy = Double(competingCorrect) / Double(max(1, competingEvaluated))
    let changesOK = Double(competingChanges) <= 1.5 * Double(leadChanges)
    checks += [changesOK, competingAccuracy >= 0.80]
    print(String(format: "%@ competing half note changes: %d (maximum 1.5 × %d lead changes)", changesOK ? "PASS":"FAIL", competingChanges, leadChanges))
    print(String(format: "%@ competing half lead pitch within ±50 cents: %.2f%% (minimum 80%%)", competingAccuracy >= 0.80 ? "PASS":"FAIL", competingAccuracy * 100))
    melody.reset()
    let resetOK = melody.current.hz == nil && melody.current.strength == 0
    let tone = (0..<Int(sr * 0.15)).map { Float(0.5 * sin(2 * .pi * 440 * Double($0)/sr)) }
    melody.onFrame = nil
    tone.withUnsafeBufferPointer { melody.ingest($0, firstSampleTime: 40) }
    let voicedTone = melody.current.hz != nil
    tone.prefix(512).withContiguousStorageIfAvailable { melody.ingest($0, firstSampleTime: 42) }
    let gapOK = melody.current.hz == nil
    tone.withUnsafeBufferPointer { melody.ingest($0, firstSampleTime: 43) }
    let silence = [Float](repeating: 0, count: Int(sr * 0.15))
    silence.withUnsafeBufferPointer { melody.ingest($0, firstSampleTime: 43.15) }
    let silenceOK = melody.current.hz == nil
    let extra = resetOK && voicedTone && gapOK && silenceOK
    print("\(extra ? "PASS":"FAIL") melody reset, timestamp discontinuity, and silence unvoice")
    melody.reset()
    var semitonesOK = true
    for (i, hz) in [440.0, 466.16376, 493.88330, 466.16376, 440.0].enumerated() {
        let samples = (0..<Int(sr * 0.2)).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / sr)) }
        samples.withUnsafeBufferPointer { melody.ingest($0, firstSampleTime: 50 + Double(i) * 0.2) }
        semitonesOK = semitonesOK && melody.current.hz.map { abs(1200 * log2($0 / hz)) <= 50 } == true
    }
    print("\(semitonesOK ? "PASS":"FAIL") semitone moves settle within ±50 cents")
    return checks + [extra, semitonesOK]
}
func schedulerSelftest() -> [Bool] {
    print("Scenario J (pure scheduler, fake clock, 20 s, 220→440 Hz glide)")
    let beats = (0..<40).map { PlannedBeat(time: 0.25 + Double($0)*0.5, kind: $0 % 3 == 0 ? .accent : .kick, strength: 0.8) }
    func run(melody: Bool, only: Bool = false, kickOnly: Bool = false) -> (thumps: [Double], chunks: [(Double, Double, Double)]) {
        var scheduler = LiveHapticScheduler(melodyOnly: only, kickOnly: kickOnly), now = 0.0
        var thumps: [Double] = [], chunks: [(Double,Double,Double)] = []
        while now < 20 {
            let next = beats.first { $0.time > scheduler.lastBeat && $0.time >= now - 0.020 }
            let hz = 220 + 220*now/20
            switch scheduler.nextAction(now: now, nextBeat: next, melody: (now, melody ? hz : nil, 0.5)) {
            case .fireThump(let beat, let at):
                thumps.append(max(now,at)); now = max(now,at) + (beat.kind == .kick ? kickDuration : accentDuration)
            case .playMelody(let hz, let duration, _):
                chunks.append((now, now+duration, hz)); now += duration
            case .wait(let until): now = max(now + 0.000001, until)
            }
        }
        return (thumps, chunks)
    }
    let on = run(melody: true), off = run(melody: false), only = run(melody: true, only: true)
    let timing = on.thumps.count == beats.count && zip(on.thumps,beats).allSatisfy { abs($0 - $1.time) <= 0.001 }
    let identical = on.thumps == off.thumps
    let noOverlap = on.chunks.allSatisfy { start, end, _ in
        beats.allSatisfy { beat in
            let stop = beat.time + (beat.kind == .kick ? kickDuration : accentDuration)
            return end <= beat.time - LiveHapticScheduler.guardTime + 1e-9 || start >= stop - 1e-9
        }
    }
    let thumpTime = beats.reduce(0.0) { $0 + ($1.kind == .kick ? kickDuration : accentDuration) }
    let coverage = on.chunks.reduce(0.0) { $0 + $1.1-$1.0 } / (20-thumpTime)
    let cycles = on.chunks.allSatisfy { abs(($0.1-$0.0)*$0.2 - (($0.1-$0.0)*$0.2).rounded()) < 1e-8 }
    let kicks = run(melody: true, kickOnly: true)
    var edge = LiveHapticScheduler()
    let low: Bool
    if case .wait = edge.nextAction(now: 0, nextBeat: nil, melody: (0,440,0.019)) { low = true } else { low = false }
    var late = LiveHapticScheduler()
    let skipped: Bool
    if case .wait = late.nextAction(now: 1, nextBeat: PlannedBeat(time: 0.9, kind: .kick, strength: 1), melody: (1,nil,0)) { skipped = true } else { skipped = false }
    var shortening = LiveHapticScheduler(), noRoom = LiveHapticScheduler()
    let shortened: Bool, waitsForBeat: Bool
    let near = PlannedBeat(time: 0.024, kind: .kick, strength: 1)
    if case .playMelody(let hz, let duration, _) = shortening.nextAction(now: 0, nextBeat: near, melody: (0,90,1)) {
        shortened = abs(duration * hz - 1) < 1e-9 && duration <= near.time - LiveHapticScheduler.guardTime
    } else { shortened = false }
    if case .wait(let until) = noRoom.nextAction(now: 0, nextBeat: PlannedBeat(time: 0.030, kind: .kick, strength: 1), melody: (0,27.5,1)) {
        waitsForBeat = until > 0 && until <= 0.030
    } else { waitsForBeat = false }
    let checks = [timing, identical, noOverlap, coverage >= 0.8, only.thumps.isEmpty, cycles, kicks.thumps.count == beats.filter { $0.kind == .kick }.count, low && skipped, shortened && waitsForBeat]
    let labels = ["every thump within ±1 ms", "thump times identical with melody off", "no melody overlaps thumps or their 3 ms guard", String(format:"melody coverage %.2f%% (minimum 80%%)",coverage*100), "melody-only produces zero thumps", "melody chunks contain whole cycles", "kick-only filters accents", "low melody level waits; late beats skipped", "shorten to whole cycles; wait when one cycle cannot fit"]
    for (ok, label) in zip(checks, labels) { print("\(ok ? "PASS":"FAIL") \(label)") }
    return checks
}

func selftest() -> Int32 {
    let track = testTrack()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beatpad-selftest-\(UUID().uuidString).wav")
    selftestTemporaryWAV = url
    atexit { if let url = selftestTemporaryWAV { try? FileManager.default.removeItem(at: url) } }
    writeWAV(track.samples, sr: 44100, url: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let audio = load(url)
    let hits = analyze(audio.mono, sr: audio.sr, mode: .onsets).hits
    print("Scenario A (onsets)")
    let kicks = hits.filter { $0.kind == .kick }
    let matched = track.kicks.compactMap { truth -> Double? in
        guard let nearest = kicks.min(by: { abs($0.time - truth) < abs($1.time - truth) }), abs(nearest.time - truth) <= 0.020 else { return nil }
        return nearest.time - truth
    }
    let falseKicks = kicks.filter { hit in !track.kicks.contains { abs(hit.time - $0) <= 0.020 } }.count
    let mean = matched.isEmpty ? Double.infinity : matched.reduce(0, +) / Double(matched.count)
    let variance = matched.isEmpty ? Double.infinity : matched.reduce(0) { $0 + pow($1 - mean, 2) } / Double(matched.count)
    let snareCount = track.snares.filter { truth in hits.contains { abs($0.time - truth) <= 0.025 } }.count
    let hatCount = track.hats.filter { truth in hits.contains { $0.kind == .accent && abs($0.time - truth) <= 0.025 } }.count
    let checks = [matched.count == track.kicks.count, falseKicks <= 1, abs(mean) <= 0.003, Double(snareCount) / Double(track.snares.count) >= 0.70]
    print("\(checks[0] ? "PASS" : "FAIL") kicks within ±20 ms: \(matched.count)/\(track.kicks.count) (detected \(kicks.count))")
    print("\(checks[1] ? "PASS" : "FAIL") false kicks: \(falseKicks) (maximum 1)")
    print(String(format: "%@ kick timing: mean %+.3f ms, std %.3f ms (mean limit ±3 ms)", checks[2] ? "PASS" : "FAIL", mean * 1000, sqrt(variance) * 1000))
    print(String(format: "%@ snares within ±25 ms: %d/%d (%.1f%%; minimum 70%%)", checks[3] ? "PASS" : "FAIL", snareCount, track.snares.count, 100 * Double(snareCount) / Double(track.snares.count)))
    print("INFO accents within ±25 ms of hats: \(hatCount)/\(track.hats.count)")
    let trackB = testTrack(beatScenario: true)
    writeWAV(trackB.samples, sr: 44100, url: url)
    let audioB = load(url)
    let resultB = analyze(audioB.mono, sr: audioB.sr)
    let beats = (1..<24).map { Double($0) * 0.5 }
    let plucks = stride(from: 0.75, to: 12.0, by: 0.5).map { $0 }
    func matches(_ truths: [Double], kind: Kind? = nil) -> Int {
        truths.filter { truth in resultB.hits.contains {
            (kind == nil || $0.kind == kind!) && abs($0.time - truth) <= 0.020
        } }.count
    }
    let beatCount = matches(beats), kickCount = matches(trackB.kicks, kind: .kick)
    let snareBCount = matches(trackB.snares, kind: .accent)
    let pluckHits = resultB.hits.filter { hit in plucks.contains { abs(hit.time - $0) <= 0.030 } }.count
    let onsetPlucks = analyze(audioB.mono, sr: audioB.sr, mode: .onsets).hits.filter { hit in
        hit.kind == .kick && plucks.contains { abs(hit.time - $0) <= 0.030 }
    }.count
    let tempo = resultB.bpm ?? 0
    let checksB = [abs(tempo - 120) <= 2, Double(beatCount) / Double(beats.count) >= 0.90,
                   Double(kickCount) / Double(trackB.kicks.count) >= 0.90,
                   Double(snareBCount) / Double(trackB.snares.count) >= 0.70, pluckHits == 0]
    print("Scenario B (beat)")
    print(String(format: "%@ tempo: %.3f bpm (120 ±2 bpm)", checksB[0] ? "PASS" : "FAIL", tempo))
    print("\(checksB[1] ? "PASS" : "FAIL") beats within ±20 ms: \(beatCount)/\(beats.count) (minimum 90%)")
    print("\(checksB[2] ? "PASS" : "FAIL") kicks as kicks within ±20 ms: \(kickCount)/\(trackB.kicks.count) (minimum 90%)")
    print("\(checksB[3] ? "PASS" : "FAIL") snares as accents within ±20 ms: \(snareBCount)/\(trackB.snares.count) (minimum 70%)")
    print("\(checksB[4] ? "PASS" : "FAIL") beat-mode hits within ±30 ms of bass plucks: \(pluckHits) (maximum 0)")
    print("INFO onsets-mode kick hits within ±30 ms of bass plucks: \(onsetPlucks)/\(plucks.count)")
    let checksC = liveSelftest()
    let checksD = longLiveSelftest()
    let checksE = metricalSelftest()
    let checksF = spliceSelftest()
    let checksG = dynamicsSelftest()
    let checksH = volumeSelftest()
    let checksI = melodySelftest()
    let checksJ = schedulerSelftest()
    let checksK = staleAudioSelftest()
    let checksL = audioAppGroupingSelftest()
    let checksM = outputPolicySelftest()
    return (checks + checksB + checksC + checksD + checksE + checksF + checksG + checksH + checksI + checksJ + checksK + checksL + checksM).allSatisfy { $0 } ? 0 : 1
}
// Mature memory, no silence, and a deliberately non-aligned first beat.
func spliceSelftest() -> [Bool] {
    let sr = 48000.0, cut = 60.0, duration = 90.0
    var checks: [Bool] = []
    print("Scenario F (hard splices, ±200 µs timestamp jitter)")
    let metricTruth = stride(from: 60.0, to: 70.0, by: 0.5).map { $0 }
    let empty = spliceRecovery([], reference: metricTruth, period: 0.5, splice: 60, end: 70)
    let sparse = spliceRecovery([MeasuredCommit(time: 61, period: 0.5)], reference: metricTruth, period: 0.5, splice: 60, end: 70)
    let alias = spliceRecovery(metricTruth.map { MeasuredCommit(time: $0, period: 1) }, reference: metricTruth, period: 0.5, splice: 60, end: 70)
    let metricsOK = empty.wrong == 0 && empty.recovery.isInfinite && sparse.recovery.isInfinite && alias.recovery.isInfinite && alias.wrong == 10
    checks.append(metricsOK)
    print("\(metricsOK ? "PASS" : "FAIL") splice metrics reject empty/sparse recovery windows and disagreeing tempos")
    for bpm in [150.0, 120.0] {
        let first = testTrack(beatScenario: true, sr: sr, duration: cut)
        let second = testTrack(beatScenario: true, sr: sr, duration: duration-cut, bpm: bpm, firstBeat: 0.23)
        let samples = first.samples + second.samples
        let p = 60/bpm
        let truth = stride(from: cut+0.23, to: duration, by: p).map { $0 }
        let tracker: LiveTracker
        do { tracker = try LiveTracker(sampleRate: sr, sensitivity: 0.5, forcedBpm: nil) }
        catch { fail(String(describing: error)) }
        var commits: [MeasuredCommit] = [], last = -Double.infinity, rng = SeededRandom()
        var gateTime: Double?
        for start in stride(from: 0, to: samples.count, by: 512) {
            let end = min(start+512,samples.count), time = Double(end)/sr
            let jitter = rng.noise()*200e-6
            samples.withUnsafeBufferPointer {
                tracker.ingest(UnsafeBufferPointer(rebasing: $0[start..<end]), firstSampleTime: Double(start)/sr+jitter)
            }
            if time >= cut, gateTime == nil, case .locking = tracker.status { gateTime = time-cut }
            if let beat = tracker.plan(after: max(last+0.25*tracker.beatPeriod,time-0.020)), beat.time <= time+0.020 {
                last = beat.time
                if beat.kind != nil { commits.append(MeasuredCommit(time:beat.time,period:tracker.beatPeriod)) }
            }
        }
        let result = spliceRecovery(commits,reference:truth,period:p,splice:cut,end:duration)
        let after = commits.filter { $0.time >= cut+10 }
        let ref = truth.filter { $0 >= cut+10 }
        let recall = Double(ref.filter { t in after.contains { abs($0.time-t)<=0.030 } }.count)/Double(ref.count)
        let precision = Double(after.filter { c in ref.contains { abs($0-c.time)<=0.030 } }.count)/Double(max(1,after.count))
        let local = [result.wrong <= 3, result.recovery <= 8, (gateTime ?? .infinity) <= 2, recall >= 0.85 && precision >= 0.85]
        checks += local
        print(String(format: "%@ 120 → %.0f bpm: wrong-thump %.3f s (maximum 3 s)",local[0] ? "PASS":"FAIL",bpm,result.wrong))
        print(String(format: "%@ re-acquire %.3f s (maximum 8 s)",local[1] ? "PASS":"FAIL",result.recovery))
        print(String(format: "%@ confidence gate %.3f s (maximum 2 s)",local[2] ? "PASS":"FAIL",gateTime ?? .infinity))
        print(String(format: "%@ post-splice recall %.2f%%, precision %.2f%% (minimum 85%%)",local[3] ? "PASS":"FAIL",100*recall,100*precision))
    }
    return checks
}

func metricalSelftest() -> [Bool] {
    let times = (0..<4000).map { Double($0) * 0.005 }
    let env = times.map { t -> Double in
        let phase = t - 0.5 - ((t - 0.5) / 0.8).rounded() * 0.8
        return exp(-0.5 * pow(phase / 0.008, 2))
    }
    let fitted = fitLivePulsePeriod(env, times: times, center: 0.81, anchor: nil)
    func extrapolationError(_ p: Double) -> Double {
        let residuals: [Double] = (0..<8).map { i in 0.5 + Double(i) * (0.8 - p) }
        let intercept = residuals.reduce(0, +) / 8.0
        return abs(intercept + 10 * p - 8.5)
    }
    let oldError = extrapolationError(0.81), newError = extrapolationError(fitted)
    let beats = (0..<4).map { PlannedBeat(time: Double($0) * 0.5, kind: $0 % 2 == 0 ? .kick : .accent, strength: 0.2 + Double($0) * 0.1) }
    let doubled = remapLiveGroove(beats, origin: 0, period: 1)
    let odd = remapLiveGroove(beats, origin: 0.5, period: 1)
    let halved = remapLiveGroove(beats, origin: 0, period: 0.25)
    let checks = [abs(fitted - 0.8) <= 0.001 && newError <= 0.005 && oldError >= 0.020,
                  doubled.count == 2 && doubled[0]?.kind == .kick && doubled[1]?.time == 1,
                  odd.count == 2 && odd[0]?.kind == .accent && odd[1]?.time == 1.5,
                  halved.count == 4 && beats.enumerated().allSatisfy { halved[2 * $0.offset]?.strength == $0.element.strength }]
    print("Scenario E (slow pulse fit and metrical groove preservation)")
    print(String(format: "%@ 75 bpm pulse period %.6f s · extrapolation error %.3f → %.3f ms (maximum 5 ms)", checks[0] ? "PASS" : "FAIL", fitted, oldError * 1000, newError * 1000))
    print("\(checks[1] ? "PASS" : "FAIL") doubled period preserves even beat subset")
    print("\(checks[2] ? "PASS" : "FAIL") doubled period preserves odd beat subset")
    print("\(checks[3] ? "PASS" : "FAIL") halved period preserves all existing strengths; midpoint slots remain new")
    return checks
}

func liveSelftest() -> [Bool] {
    let sr = 48000.0
    let c1 = testTrack(beatScenario: true, sr: sr, duration: 10)
    let c3 = testTrack(beatScenario: true, sr: sr, duration: 10, bpm: 100, firstBeat: 0.37)
    var rng = SeededRandom()
    let silence = (0..<Int(1.5 * sr)).map { _ in Float(pow(10, -70.0 / 20) * rng.noise()) }
    let audio = c1.samples + silence + c3.samples
    let tracker: LiveTracker
    do { tracker = try LiveTracker(sampleRate: sr, sensitivity: 0.5, forcedBpm: nil) }
    catch { fail(String(describing: error)) }
    var commits: [PlannedBeat] = [], commitTimes: [Double] = [], last = -100.0
    var lock1: Double?, lock3: Double?, bpm1 = 0.0, bpm3 = 0.0
    for start in stride(from: 0, to: audio.count, by: 512) {
        let end = min(audio.count, start + 512), t = Double(end) / sr
        audio.withUnsafeBufferPointer { pointer in
            tracker.ingest(UnsafeBufferPointer(rebasing: pointer[start..<end]), firstSampleTime: Double(start) / sr)
        }
        if case .locked(let bpm) = tracker.status {
            if t < 10 { if lock1 == nil { lock1 = t }; bpm1 = bpm }
            if t >= 11.5 { if lock3 == nil { lock3 = t - 11.5 }; bpm3 = bpm }
        }
        if let beat = tracker.plan(after: max(last + 0.25 * tracker.beatPeriod, t - 0.020)), beat.time <= t + 0.020 {
            last = beat.time
            if beat.kind != nil { commits.append(beat); commitTimes.append(t) }
        }
    }
    print("Scenario C (live)")
    // A prediction committed just before a pause cannot be recalled. Check the
    // commit boundary for silence; use scheduled beat times for timing accuracy.
    let quiet = !commitTimes.contains { (10..<11.5).contains($0) || $0 < 2 || (11.5..<13.5).contains($0) }
    print("\(quiet ? "PASS" : "FAIL") no commits during silence or first 2 s of C1/C3")
    var checks = [quiet]
    for (label, base, first, period, kicks, lock, bpm) in [
        ("C1", 0.0, 0.5, 0.5, c1.kicks, lock1, bpm1),
        ("C3", 11.5, 0.37, 0.6, c3.kicks, lock3, bpm3)
    ] {
        let truth = stride(from: first, to: 10.0, by: period).filter { $0 >= 5 }.map { base + $0 }
        let window = commits.filter { (base + 5..<base + 10).contains($0.time) }
        let errors = truth.compactMap { t -> Double? in
            guard let nearest = window.min(by: { abs($0.time - t) < abs($1.time - t) }), abs(nearest.time - t) <= 0.020 else { return nil }
            return nearest.time - t
        }
        let mean = errors.isEmpty ? Double.infinity : errors.reduce(0, +) / Double(errors.count)
        let trueKicks = kicks.filter { $0 >= 5 }.map { base + $0 }
        let matched = trueKicks.filter { t in window.contains { $0.kind == .kick && abs($0.time - t) <= 0.020 } }.count
        let plucks = stride(from: first + period / 2, to: 10.0, by: period).filter { $0 >= 5 }.map { base + $0 }
        let falseHits = window.filter { hit in plucks.contains { abs(hit.time - $0) <= 0.030 } }.count
        let local = [Double(errors.count) / Double(truth.count) >= 0.90, abs(mean) <= 0.008,
                     Double(matched) / Double(trueKicks.count) >= 0.80, falseHits == 0]
        checks += local
        print(String(format: "INFO %@ lock after %.3f s · detected %.3f bpm", label, lock ?? .infinity, bpm))
        print("\(local[0] ? "PASS" : "FAIL") \(label) last 5 s beats within ±20 ms: \(errors.count)/\(truth.count) (minimum 90%)")
        print(String(format: "%@ %@ timing mean %+.3f ms (limit ±8 ms)", local[1] ? "PASS" : "FAIL", label, mean * 1000))
        print("\(local[2] ? "PASS" : "FAIL") \(label) kicks as kicks: \(matched)/\(trueKicks.count) (minimum 80%)")
        print("\(local[3] ? "PASS" : "FAIL") \(label) commits within ±30 ms of bass plucks: \(falseHits) (maximum 0)")
    }
    return checks
}

func longLiveSelftest() -> [Bool] {
    let sr = 48000.0, duration = 180.0
    let audio = testTrack(beatScenario: true, sr: sr, duration: duration)
    let tracker: LiveTracker
    do { tracker = try LiveTracker(sampleRate: sr, sensitivity: 0.5, forcedBpm: nil) }
    catch { fail(String(describing: error)) }
    var rng = SeededRandom(), commits: [PlannedBeat] = []
    var last = -Double.infinity, firstLock: Double?, initialRelocks = 0
    for start in stride(from: 0, to: audio.samples.count, by: 512) {
        let end = min(start + 512, audio.samples.count), t = Double(end) / sr
        let jitter = rng.noise() * 200e-6
        audio.samples.withUnsafeBufferPointer {
            tracker.ingest(UnsafeBufferPointer(rebasing: $0[start..<end]), firstSampleTime: Double(start) / sr + jitter)
        }
        if case .locked = tracker.status, firstLock == nil { firstLock = t; initialRelocks = tracker.relocks }
        if let beat = tracker.plan(after: max(last + 0.25 * tracker.beatPeriod, t - 0.020)), beat.time <= t + 0.020 {
            last = beat.time
            if beat.kind != nil { commits.append(beat) }
        }
    }
    let truth = stride(from: 150.0, to: duration, by: 0.5).map { $0 }
    let errors = truth.compactMap { t -> Double? in
        guard let nearest = commits.min(by: { abs($0.time - t) < abs($1.time - t) }), abs(nearest.time - t) <= 0.020 else { return nil }
        return nearest.time - t
    }
    let mean = errors.isEmpty ? Double.infinity : errors.reduce(0, +) / Double(errors.count)
    let kicks = audio.kicks.filter { $0 >= 150 }
    let matched = kicks.filter { t in commits.contains { $0.kind == .kick && abs($0.time - t) <= 0.020 } }.count
    let plucks = stride(from: 0.75, to: duration, by: 0.5)
    let falseHits = commits.filter { hit in plucks.contains { abs(hit.time - $0) <= 0.030 } }.count
    let allKicks = audio.kicks.filter { t in commits.contains { $0.kind == .kick && abs($0.time - t) <= 0.020 } }.count
    let relocks = tracker.relocks - initialRelocks
    let checks = [firstLock != nil && relocks == 0, Double(errors.count) / Double(truth.count) >= 0.95,
                  abs(mean) <= 0.008, Double(matched) / Double(kicks.count) >= 0.80, falseHits == 0,
                  Double(allKicks) / Double(audio.kicks.count) >= 0.80]
    print("Scenario D (180 s live, ±200 µs timestamp jitter)")
    print(String(format: "%@ relocks after first lock: %d (maximum 0) · lock after %.3f s", checks[0] ? "PASS" : "FAIL", relocks, firstLock ?? .infinity))
    print("\(checks[1] ? "PASS" : "FAIL") last 30 s beats within ±20 ms: \(errors.count)/\(truth.count) (minimum 95%)")
    print(String(format: "%@ timing mean %+.3f ms (limit ±8 ms)", checks[2] ? "PASS" : "FAIL", mean * 1000))
    print("\(checks[3] ? "PASS" : "FAIL") last 30 s kicks as kicks: \(matched)/\(kicks.count) (minimum 80%)")
    print("\(checks[4] ? "PASS" : "FAIL") commits within ±30 ms of bass plucks: \(falseHits) (maximum 0)")
    print("\(checks[5] ? "PASS" : "FAIL") all 180 s kicks as kicks: \(allKicks)/\(audio.kicks.count) (minimum 80%)")
    return checks
}

func dynamicsSelftest() -> [Bool] {
    print("Scenario G (60 s dynamics, 120 bpm, ±200 µs timestamp jitter)")
    let sr = 48000.0, duration = 60.0
    let track = testTrack(beatScenario: true, sr: sr, duration: duration)
    // A sustained pad supplies steady full-band energy between drum transients.
    // The entire mix, including the pad, drops by exactly 12 dB at 20 s.
    let samples = track.samples.enumerated().map { i, value -> Float in
        let t = Double(i) / sr
        let mix = Double(value) + 0.45 * sin(2 * .pi * 1000 * t)
        return Float(mix * ((20..<40).contains(t) ? pow(10, -12.0 / 20) : 1))
    }
    let tracker: LiveTracker
    do { tracker = try LiveTracker(sampleRate: sr, sensitivity: 0.5, forcedBpm: nil) }
    catch { fail(String(describing: error)) }
    var rng = SeededRandom(), last = -Double.infinity, firstLock: Double?
    var commits: [(time: Double, beat: PlannedBeat, gain: Double)] = []
    var settledDown: Double?, settledUp: Double?, minimumGain = 1.0
    for start in stride(from: 0, to: samples.count, by: 512) {
        let end = min(start + 512, samples.count), t = Double(end) / sr
        let jitter = rng.noise() * 200e-6
        samples.withUnsafeBufferPointer {
            tracker.ingest(UnsafeBufferPointer(rebasing: $0[start..<end]), firstSampleTime: Double(start) / sr + jitter)
        }
        minimumGain = min(minimumGain, tracker.dynamicsGain)
        if case .locked = tracker.status, firstLock == nil { firstLock = t }
        if t >= 20 && t < 40 && settledDown == nil && abs(tracker.dynamicsGain - 0.48) <= 0.10 { settledDown = t - 20 }
        if t >= 40 && settledUp == nil && tracker.dynamicsGain >= 0.9 { settledUp = t - 40 }
        if let beat = tracker.plan(after: max(last + 0.25 * tracker.beatPeriod, t - 0.020)), beat.time <= t + 0.020 {
            last = beat.time
            if beat.kind != nil { commits.append((t, beat, tracker.dynamicsGain)) }
        }
    }
    let loud = commits.filter { $0.time < 20 || $0.time >= 41.5 }.map { $0.gain }
    let quiet = commits.filter { (21.5..<40).contains($0.time) }.map { $0.gain }
    let quietMean = quiet.reduce(0, +) / Double(max(1, quiet.count))
    var checks = [!loud.isEmpty && loud.allSatisfy { $0 >= 0.9 },
                  !quiet.isEmpty && quiet.allSatisfy { abs($0 - 0.48) <= 0.10 },
                  minimumGain >= dynamicsFloor,
                  (settledDown ?? .infinity) <= 1.5 && (settledUp ?? .infinity) <= 1.5]
    print(String(format: "%@ loud commit gain minimum %.3f (minimum 0.9)", checks[0] ? "PASS" : "FAIL", loud.min() ?? 0))
    print(String(format: "%@ quiet commit gain %.3f…%.3f, mean %.3f (0.48 ±0.10)", checks[1] ? "PASS" : "FAIL", quiet.min() ?? 0, quiet.max() ?? 0, quietMean))
    print(String(format: "%@ dynamics floor: minimum %.3f (floor %.2f)", checks[2] ? "PASS" : "FAIL", minimumGain, dynamicsFloor))
    print(String(format: "%@ settles down %.3f s / up %.3f s (maximum 1.5 s)", checks[3] ? "PASS" : "FAIL", settledDown ?? .infinity, settledUp ?? .infinity))
    // Scenario C tracking thresholds in each section, including the quiet mix.
    let startup = !commits.contains { $0.time < 2 } && firstLock != nil
    checks.append(startup)
    print("\(startup ? "PASS" : "FAIL") no commits during first 2 s; tracker locks")
    for base in [0.0, 20.0, 40.0] {
        let truth = stride(from: base + 5, to: base + 20, by: 0.5).map { $0 }
        let window = commits.filter { (base + 5..<base + 20).contains($0.beat.time) }.map { $0.beat }
        let errors = truth.compactMap { t -> Double? in
            guard let nearest = window.min(by: { abs($0.time-t) < abs($1.time-t) }), abs(nearest.time-t) <= 0.020 else { return nil }
            return nearest.time-t
        }
        let mean = errors.reduce(0, +) / Double(max(1, errors.count))
        let kicks = track.kicks.filter { (base + 5..<base + 20).contains($0) }
        let matched = kicks.filter { t in window.contains { $0.kind == .kick && abs($0.time-t) <= 0.020 } }.count
        let plucks = stride(from: base + 5.25, to: base + 20, by: 0.5)
        let falseHits = window.filter { hit in plucks.contains { abs(hit.time-$0) <= 0.030 } }.count
        let ok = Double(errors.count) / Double(truth.count) >= 0.90 && abs(mean) <= 0.008 && Double(matched) / Double(kicks.count) >= 0.80 && falseHits == 0
        checks.append(ok)
        print(String(format: "%@ G %.0f–%.0f s tracking: beats %d/%d · timing %+.3f ms · kicks %d/%d · bass plucks %d", ok ? "PASS" : "FAIL", base, base+20, errors.count, truth.count, mean*1000, matched, kicks.count, falseHits))
    }
    // Centered windows/global reference and smoothing also work without a motor.
    let hits = [10.0, 30.0, 50.0].map { Hit(time: $0, kind: .kick, strength: 1) }
    let gains = fileDynamics(samples, rate: sr, hits: hits, range: 15)
    let fileOK = gains[0] >= 0.9 && abs(gains[1]-0.48) <= 0.10 && gains[2] >= 0.9
    checks.append(fileOK)
    print(String(format: "%@ file centered/global-reference gains %.3f / %.3f / %.3f", fileOK ? "PASS" : "FAIL", gains[0], gains[1], gains[2]))
    let disabled: LiveTracker
    do { disabled = try LiveTracker(sampleRate: sr, sensitivity: 0.5, forcedBpm: nil, dynamicsEnabled: false) }
    catch { fail(String(describing: error)) }
    samples.withUnsafeBufferPointer { disabled.ingest(UnsafeBufferPointer(rebasing: $0[0..<512]), firstSampleTime: 0) }
    checks.append(disabled.dynamicsGain == 1)
    print("\(checks.last! ? "PASS" : "FAIL") disabled dynamics gain is 1")
    return checks
}

func volumeSelftest() -> [Bool] {
    print("Scenario H (pure volume mapping; no hardware)")
    let checks = [listeningVolumeGain(scalar: 0.8, muted: true) == 0,
                  listeningVolumeGain(scalar: 0.5, muted: false) == 0.5,
                  listeningVolumeGain(scalar: nil, muted: nil) == 1 && listeningVolumeGain(scalar: 0.5, muted: nil) == 1,
                  !shouldActuate(effectiveLevel(master: 0.6, dynamics: 0.35, volume: 0.05, shaping: 1)) && !shouldActuate(0) && shouldActuate(0.02),
                  effectiveLevel(master: 0.6, dynamics: 0.48, volume: 0.5, shaping: 1) == 0.6 * 0.48 * 0.5]
    for (ok, label) in zip(checks, ["muted → 0", "scalar 0.5 → 0.5", "unreadable → 1", "effective level below 0.02 → skipped; 0.02 retained", "master × dynamics × volume × shaping"]) {
        print("\(ok ? "PASS" : "FAIL") \(label)")
    }
    return checks
}


// Also handles exit() in audio file error reporting, where Swift defers do not run.
private var selftestTemporaryWAV: URL?

func staleAudioSelftest() -> [Bool] {
    print("Scenario K (capture stops, monotonic fake clock)")
    let rate = 48000.0
    let audio = testTrack(beatScenario: true, sr: rate, duration: 20).samples
    let tracker: LiveTracker
    do { tracker = try LiveTracker(sampleRate: rate, sensitivity: 0.5, forcedBpm: 120) }
    catch { fail(String(describing: error)) }
    let melody: LiveMelody
    do { melody = try LiveMelody(sampleRate: rate) }
    catch { fail(String(describing: error)) }
    audio.withUnsafeBufferPointer { data in
        for start in stride(from: 0, to: data.count, by: 512) {
            let chunk = UnsafeBufferPointer(rebasing: data[start..<min(start + 512, data.count)])
            tracker.ingest(chunk, firstSampleTime: Double(start) / rate)
            melody.ingest(chunk, firstSampleTime: Double(start) / rate)
        }
    }
    let locked = tracker.plan(after: 20) != nil
    let generation = tracker.resetGeneration
    var actuations = 0
    var scheduler = LiveHapticScheduler()
    for time in stride(from: 20.501, to: 22.1, by: 0.005) {
        let fresh = tracker.audioIsFresh(at: time)
        if tracker.resetGeneration != generation { melody.reset() }
        let beat = fresh ? tracker.plan(after: time) : nil
        let note: MelodyFrame = (time, fresh ? 220 : nil, 0.5)
        switch scheduler.nextAction(now: time, nextBeat: beat, melody: note) {
        case .wait: break
        default: actuations += 1
        }
    }
    let reset = tracker.resetGeneration == generation + 1 && tracker.plan(after: 22.1) == nil && melody.current.hz == nil
    let checks = [locked, actuations == 0, reset]
    for (ok, label) in zip(checks, ["synthetic audio locks before capture stops", "zero thumps or melody after 0.5 s without audio", "tracker and melody reset after 2 s without audio"]) {
        print("\(ok ? "PASS" : "FAIL") \(label)")
    }
    return checks
}

func audioAppGroupingSelftest() -> [Bool] {
    let apps: [(bundle: String, pid: pid_t)] = [
        ("org.example.Player", 100), ("org.example.Player.Pro", 200)
    ]
    let cases: [(bundle: String, pid: pid_t, expected: Int?)] = [
        ("org.example.Player", 100, 0),
        ("org.example.Player.Pro", 200, 1),
        ("ORG.EXAMPLE.PLAYER.PRO", 201, 1),
        ("org.example.Player.Pro.helper", 200, 1),
        ("org.example.Player.helper", 200, 1),
        ("org.example.Player.helper", 101, 0),
        ("org.example.Player.Pro.helper", 201, 1),
        ("org.example.Player.Professional", 300, 0),
        ("org.example.PlayerPro", 300, nil),
        ("", 200, 1),
        ("org.other.App", 300, nil)
    ]
    let checks = cases.map { audioAppIndex(bundle: $0.bundle, pid: $0.pid, apps: apps) == $0.expected }
    print("\(checks.allSatisfy { $0 } ? "PASS" : "FAIL") app grouping keeps Player/Player.Pro distinct; exact bundle/PID before longest dotted prefix")
    return checks
}

func outputPolicySelftest() -> [Bool] {
    print("Scenario M (output/lid policy and scheduler; no hardware)")
    let builtIn = kAudioDeviceTransportTypeBuiltIn
    let speakers: UInt32 = 0x6973706b, headphones: UInt32 = 0x6864706e
    let outputs: [(String, UInt32?, UInt32?, String, Bool)] = [
        ("built-in speakers", builtIn, speakers, "Internal audio", true),
        ("built-in headphones", builtIn, headphones, "Speakers / Headphones", false),
        ("USB", kAudioDeviceTransportTypeUSB, nil, "USB Speakers", false),
        ("HDMI", kAudioDeviceTransportTypeHDMI, nil, "Monitor", false),
        ("DisplayPort", kAudioDeviceTransportTypeDisplayPort, nil, "Monitor", false),
        ("Bluetooth", kAudioDeviceTransportTypeBluetooth, nil, "Wireless", false),
        ("virtual", kAudioDeviceTransportTypeVirtual, nil, "Virtual Speakers", false),
        ("aggregate", kAudioDeviceTransportTypeAggregate, nil, "Aggregate", false),
        ("speaker name fallback", builtIn, nil, "MacBook Air Speakers", true),
        ("MacBook Pro speaker fallback", builtIn, nil, "MacBook Pro Speakers", true),
        ("internal speaker fallback", builtIn, nil, "Internal Speakers", true),
        ("plain speaker fallback", builtIn, nil, "Speakers", true),
        ("trimmed speaker fallback", builtIn, nil, " \tSpeakers\n", true),
        ("case-insensitive fallback", builtIn, nil, "Internal sPeAkErS", true),
        ("headphone name fallback", builtIn, nil, "External Headphones", false),
        ("combined headphone/speaker fallback", builtIn, nil, "Headphones / Speakers", false),
        ("combined headset/speaker fallback", builtIn, nil, "Headset & Speakers", false),
        ("USB speaker name fallback", builtIn, nil, "USB Speakers", false),
        ("numbered speaker fallback", builtIn, nil, "Speakers 2", false),
        ("line speaker fallback", builtIn, nil, "Line Speakers", false),
        ("output speaker fallback", builtIn, nil, "Output Speakers", false),
        ("combined plus fallback", builtIn, nil, "Internal + Speakers", false),
        ("built-in speaker fallback", builtIn, nil, "Built-in Speakers", true),
        ("unknown output", nil, nil, "unknown output", false),
        ("unknown data source", builtIn, 0, "Speakers", false)
    ]
    var checks: [Bool] = []
    for (label, transport, source, name, expected) in outputs {
        var ok = true
        for lid in [false, true] {
            for any in [false, true] {
                for external in [false, true] {
                    let result = hapticsAllowed(outputTransport: transport, outputDataSource: source.map { .value($0) } ?? .absent, outputName: name,
                                                lid: lid ? .closed : .open, anyOutput: any, externalTrackpad: external)
                    let allowed = external || (!lid && transport != nil && (any || expected))
                    let reason = allowed ? nil : (lid ? "lid closed" : transport == nil ? "couldn't read the output route" :
                        "sound is going to \"\(name)\"; the trackpad only runs on the built-in speakers (use --any-output to allow)")
                    ok = ok && result.allowed == allowed && result.reason == reason
                }
            }
        }
        checks.append(ok)
        print("\(ok ? "PASS" : "FAIL") \(label): default, any output, lid and external combinations")
    }
    let desktopMotorBuiltIn = false, desktopExternalFlag = false
    let extra: [(String, UInt32?, PropertyRead<UInt32>, String, LidState, Bool, Bool, Bool, String?)] = [
        ("unknown lid on built-in", builtIn, .value(speakers), "Speakers", .unknown, false, false, false, "lid state unavailable"),
        ("unknown lid on external", builtIn, .value(speakers), "Speakers", .unknown, false, true, true, nil),
        ("data source read failed", builtIn, .failed, "MacBook Pro Speakers", .open, false, false, false, "couldn't read the output route"),
        ("absent source with speaker suffix", builtIn, .absent, "MacBook Air Speakers", .open, false, false, true, nil),
        ("absent source with headphone suffix", builtIn, .absent, "Speakers / Headphones", .open, false, false, false, nil),
        ("unreadable transport", nil, .value(speakers), "Speakers", .open, false, false, false, "couldn't read the output route"),
        ("unreadable device with any output", nil, .failed, "unknown output", .open, true, false, false, "couldn't read the output route"),
        ("unreadable source with any output", builtIn, .failed, "Speakers", .open, true, false, false, "couldn't read the output route"),
        ("desktop external actuator without flag", kAudioDeviceTransportTypeUSB, .absent, "USB", .unknown, desktopExternalFlag, !desktopMotorBuiltIn, true, nil)
    ]
    for (label, transport, source, name, lid, any, external, allowed, reason) in extra {
        let result = hapticsAllowed(outputTransport: transport, outputDataSource: source, outputName: name,
                                    lid: lid, anyOutput: any, externalTrackpad: external)
        let ok = result.allowed == allowed && (reason == nil || result.reason == reason)
        checks.append(ok); print("\(ok ? "PASS" : "FAIL") \(label)")
    }
    var time = 10.0
    let snapshot = PolicySnapshot(clock: { time })
    func publish(_ allowed: Bool) {
        snapshot.publish((allowed, allowed ? nil : "test pause"), startedAt: time, version: snapshot.version)
    }
    func check(_ ok: Bool, _ label: String) {
        checks.append(ok); print("\(ok ? "PASS" : "FAIL") \(label)")
    }
    publish(true)
    time += 1
    check(snapshot.current.allowed, "snapshot exactly one second old remains fresh")
    time += 0.001
    check(!snapshot.current.allowed && snapshot.current.reason == "output check stalled", "snapshot older than one second denies")
    publish(true)
    let oldVersion = snapshot.version
    snapshot.invalidate()
    check(!snapshot.current.allowed, "change notification denies before re-evaluation")
    snapshot.publish((true, nil), startedAt: time, version: oldVersion)
    check(!snapshot.current.allowed, "in-flight evaluation cannot overwrite notification")
    publish(true)
    check(snapshot.current.allowed, "fresh evaluation resumes after notification")
    var actuations = 0
    let hook = { actuations += 1 }
    publish(false)
    for _ in 0..<10 { play([(220, 1)], ms: 40, level: 1, policy: snapshot, actuationHook: hook) }
    check(actuations == 0, "play gate emits zero actuations while denied")
    publish(true)
    play([(220, 1)], ms: 40, level: 1, policy: snapshot, actuationHook: hook)
    check(actuations == 1, "play gate invokes fake actuator when allowed")
    time += 1.001
    play([(220, 1)], ms: 40, level: 1, policy: snapshot, actuationHook: hook)
    publish(true); snapshot.invalidate()
    play([(220, 1)], ms: 40, level: 1, policy: snapshot, actuationHook: hook)
    check(actuations == 1, "play gate rejects stale and invalidated snapshots")
    publish(false)
    let initialPolicy = snapshot.current
    publish(true)
    check(hapticsPauseMessage(initialPolicy) == "Haptics paused — test pause" && hapticsPauseMessage(snapshot.current) == nil,
          "startup notice uses one snapshot across policy recovery")
    check(hapticsPauseMessage((false, nil)) == "Haptics paused — output unavailable", "startup notice handles missing reason")

    // Hold a submission in its closure while a second thread tries to invalidate.
    let atomic = PolicySnapshot(clock: { 0 })
    atomic.publish((true, nil), startedAt: 0, version: atomic.version)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let invalidating = DispatchSemaphore(value: 0), invalidated = DispatchSemaphore(value: 0)
    let submitted = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        atomic.submit { entered.signal(); release.wait() }
        submitted.signal()
    }
    entered.wait()
    DispatchQueue.global().async { invalidating.signal(); atomic.invalidate(); invalidated.signal() }
    invalidating.wait()
    let blocked = invalidated.wait(timeout: .now() + .milliseconds(30)) == .timedOut
    release.signal(); submitted.wait()
    if blocked { invalidated.wait() }
    var afterInvalidation = 0
    atomic.submit { afterInvalidation += 1 }
    check(blocked && afterInvalidation == 0, "invalidation serializes with submit and completed invalidation rejects later submission")

    var monitorTime = 0.0, lidReads = 0
    var route = OutputObservation(device: 42, transport: builtIn, dataSource: .value(speakers), name: "Internal Speakers")
    var attempts: [String: Int] = [:]
    var callbacks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    var removalAttempts: [AudioObjectID: Int] = [:]
    let stoppedCleanup = DispatchSemaphore(value: 0)
    let monitor = OutputVolume(following: false, clock: { monitorTime }, lidReader: { lidReads += 1; return .open },
        routeReader: { route }, automatic: false,
        install: { object, address, _, block in
            let key = "\(object):\(address.mSelector)"
            attempts[key, default: 0] += 1
            callbacks[object] = block
            return attempts[key] == 1 ? kAudioHardwareUnspecifiedError : noErr
        }, uninstall: { object, _, _, _ in
            removalAttempts[object, default: 0] += 1
            if object == AudioObjectID(kAudioObjectSystemObject) && removalAttempts[object] == 2 { stoppedCleanup.signal() }
            return removalAttempts[object] == 1 ? kAudioHardwareUnspecifiedError : noErr
        })
    monitor.start(externalTrackpad: false)
    check(!monitor.haptics.allowed, "failed system and device listener registrations deny")
    monitorTime = 0.25; monitor.refresh()
    check(monitor.haptics.allowed && attempts.values.allSatisfy { $0 == 2 }, "next tick retries all missing listeners and recovers on unchanged device")
    for tick in [0.5, 0.75] { monitorTime = tick; monitor.refresh() }
    monitorTime = 1.001
    check(lidReads == 4 && monitor.haptics.allowed, "each evaluation renews the lid observation")
    monitor.refresh()
    check(monitor.haptics.allowed && lidReads == 5, "next evaluation reads the lid again")
    var systemAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let beforeSystemNotification = monitor.snapshot.version
    callbacks[AudioObjectID(kAudioObjectSystemObject)]?(1, &systemAddress)
    check(monitor.snapshot.version > beforeSystemNotification, "system listener always invalidates the current route")
    monitor.refresh()
    route.device = 43
    monitor.refresh(); monitor.refresh()
    let oldVersionAfterSwitch = monitor.snapshot.version
    var callbackAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    callbacks[42]?(1, &callbackAddress)
    check(monitor.snapshot.version == oldVersionAfterSwitch, "obsolete device callbacks cannot invalidate current policy")
    check((removalAttempts[42] ?? 0) >= 2, "failed device listener removals are retained and retried")
    monitor.stop()
    check(!monitor.haptics.allowed, "monitor stop revokes permission")
    check(stoppedCleanup.wait(timeout: .now() + 2) == .success, "failed shutdown listener removal is retried after stop")

    for anyOutput in [false, true] {
        var steadyTime = 0.0, steadyLidReads = 0
        let steadyMonitor = OutputVolume(following: false, anyOutput: anyOutput, clock: { steadyTime },
            lidReader: { steadyLidReads += 1; return .open },
            routeReader: { OutputObservation(device: 42, transport: builtIn, dataSource: .value(speakers), name: "Internal Speakers") },
            automatic: false, install: { _, _, _, _ in noErr }, uninstall: { _, _, _, _ in noErr })
        steadyMonitor.start(externalTrackpad: false)
        // Evaluate on a 250 ms cadence with deterministic 0–20 ms timer jitter.
        // Sample between evaluations as well as on ticks to catch transient stalls.
        let jitter = [0.0, 0.005, 0.015, 0.01, 0.02]
        var tick = 1, evaluations = 1, lastEvaluation = 0.0
        var alwaysAllowed = true, neverStalled = true
        for sample in 0...1000 {
            let sampleTime = Double(sample) / 100
            while Double(tick) * 0.25 + jitter[tick % jitter.count] <= sampleTime {
                steadyTime = Double(tick) * 0.25 + jitter[tick % jitter.count]
                steadyMonitor.refresh()
                lastEvaluation = steadyTime
                evaluations += 1; tick += 1
            }
            steadyTime = sampleTime
            let policy = steadyMonitor.snapshot.current
            alwaysAllowed = alwaysAllowed && policy.allowed
            neverStalled = neverStalled && policy.reason != "output check stalled"
        }
        let label = anyOutput ? "any output" : "built-in speakers"
        check(alwaysAllowed && neverStalled && steadyLidReads == evaluations,
              "\(label): 10 s of jittered evaluations stays allowed at every 10 ms sample")
        var stalledAt: Double?
        for sample in 1...110 {
            steadyTime = 10 + Double(sample) / 100
            let policy = steadyMonitor.snapshot.current
            if !policy.allowed && policy.reason == "output check stalled" {
                stalledAt = steadyTime
                break
            }
        }
        check(stalledAt.map { $0 - lastEvaluation <= 1.1 } ?? false,
              "\(label): halted evaluations report stalled within 1.1 s")
        steadyMonitor.stop()
    }

    let externalMonitor = OutputVolume(following: false, clock: { monitorTime }, lidReader: { .unknown },
        routeReader: { OutputObservation(device: 0, transport: nil, dataSource: .failed, name: "unknown output") }, automatic: false,
        install: { _, _, _, _ in kAudioHardwareUnspecifiedError }, uninstall: { _, _, _, _ in noErr })
    externalMonitor.start(externalTrackpad: true)
    externalMonitor.snapshot.invalidate()
    monitorTime += 100
    check(externalMonitor.haptics.allowed, "external actuator ignores notifications, stale observations and listener failures")
    var externalActuations = 0
    play([(220, 1)], ms: 40, level: 1, policy: externalMonitor.snapshot, actuationHook: { externalActuations += 1 })
    externalMonitor.stop()
    play([(220, 1)], ms: 40, level: 1, policy: externalMonitor.snapshot, actuationHook: { externalActuations += 1 })
    check(!externalMonitor.haptics.allowed && externalActuations == 1, "external actuator stop revokes fixed permission at submit gate")
    let rate = 48000.0
    let audio = testTrack(beatScenario: true, sr: rate, duration: 20).samples
    let tracker: LiveTracker
    do { tracker = try LiveTracker(sampleRate: rate, sensitivity: 0.5, forcedBpm: 120) }
    catch { fail(String(describing: error)) }
    var scheduler = LiveHapticScheduler(), melodyOnly = LiveHapticScheduler(melodyOnly: true)
    var deniedThumps = 0, deniedNotes = 0, resumedThumps = 0, resumedNotes = 0, trackedWhilePaused = 0
    audio.withUnsafeBufferPointer { data in
        for start in stride(from: 0, to: data.count, by: 512) {
            let end = min(start + 512, data.count), time = Double(end) / rate
            tracker.ingest(UnsafeBufferPointer(rebasing: data[start..<end]), firstSampleTime: Double(start) / rate)
            let allowed = hapticsAllowed(outputTransport: kAudioDeviceTransportTypeUSB, outputDataSource: .absent,
                                         outputName: "USB", lid: .open, anyOutput: time >= 15,
                                         externalTrackpad: false).allowed
            let beat = tracker.plan(after: time - LiveHapticScheduler.late)
            if !allowed && beat != nil { trackedWhilePaused += 1 }
            let note: MelodyFrame = (time, 220, 0.5)
            switch scheduler.nextAction(now: time, nextBeat: beat, melody: note, allowed: allowed) {
            case .fireThump:
                if allowed { resumedThumps += 1 } else { deniedThumps += 1 }
            case .playMelody:
                if allowed { resumedNotes += 1 } else { deniedNotes += 1 }
            case .wait: break
            }
            if case .playMelody = melodyOnly.nextAction(now: time, nextBeat: beat, melody: note, allowed: allowed) {
                if allowed { resumedNotes += 1 } else { deniedNotes += 1 }
            }
        }
    }
    let schedulerChecks = [deniedThumps == 0 && deniedNotes == 0, trackedWhilePaused > 0,
                           resumedThumps > 0 && resumedNotes > 0]
    for (ok, label) in zip(schedulerChecks, ["disallowed scheduler emits zero thumps and melody (including melody-only)",
                                           "tracking keeps planning beats while paused", "thumps and melody resume when output becomes allowed"]) {
        print("\(ok ? "PASS" : "FAIL") \(label)")
    }
    return checks + schedulerChecks
}
