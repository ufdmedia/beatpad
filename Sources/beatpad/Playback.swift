import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

func hapticsPauseMessage(_ policy: HapticsDecision) -> String? {
    policy.allowed ? nil : "Haptics paused — \(policy.reason ?? "output unavailable")"
}

func timestamp(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    return String(format: "%d:%02d", value / 60, value % 60)
}
func printHits(_ hits: [Hit], startSec: Double) {
    let selected = hits.filter { $0.time >= startSec }
    for hit in selected { print(String(format: "%.6f\t%@\t%.3f", hit.time, hit.kind.rawValue, hit.strength)) }
    print("Totals: kicks \(selected.filter { $0.kind == .kick }.count), accents \(selected.filter { $0.kind == .accent }.count), hits \(selected.count)")
}
func playback(file: AVAudioFile?, buffer: AVAudioPCMBuffer?, duration: Double, name: String, hits: [Hit], options: Options, bpm: Double? = nil, dynamicsGains: [Double]? = nil) {
    let volume = OutputVolume(following: options.followVolume, anyOutput: options.anyOutput, externalTrackpad: options.external)
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    engine.attach(player)
    let format = file?.processingFormat ?? buffer!.format
    engine.connect(player, to: engine.mainMixerNode, format: format)
    if let file {
        file.framePosition = 0
        if options.start > 0 {
            let first = AVAudioFramePosition(options.start * format.sampleRate)
            player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(file.length - first), at: nil)
        } else { player.scheduleFile(file, at: nil) }
    } else if let buffer {
        if options.start > 0 {
            let first = Int(options.start * format.sampleRate)
            guard let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength - AVAudioFrameCount(first)) else {
                fail("Couldn't allocate the metronome playback buffer.")
            }
            trimmed.frameLength = trimmed.frameCapacity
            for c in 0..<Int(format.channelCount) {
                trimmed.floatChannelData![c].update(from: buffer.floatChannelData![c].advanced(by: first), count: Int(trimmed.frameLength))
            }
            player.scheduleBuffer(trimmed, at: nil)
        } else { player.scheduleBuffer(buffer, at: nil) }
    }
    // Deliver signals on a dispatch queue; never acquire a lock in a POSIX signal handler.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { state.stop() }
        source.resume()
        return source
    }
    defer { for source in signals { source.cancel() } }
    engine.prepare()
    do { try engine.start() } catch { fail("Couldn't start audio output: \(error.localizedDescription)") }
    motor = openMotor()
    motorPointer = Unmanaged.passUnretained(motor! as AnyObject).toOpaque()
    motorPolicy = volume.snapshot
    volume.start(externalTrackpad: !motorBuiltIn)
    defer { volume.stop() }
    let initialPolicy = volume.haptics
    var wasAllowed = initialPolicy.allowed
    if let message = hapticsPauseMessage(initialPolicy) { print(message) }
    defer {
        player.stop(); engine.stop()
        if let motor { _ = actuatorClose?(motor) }
        motorPointer = nil; motor = nil
        print("")
    }
    let indices = hits.indices.filter { hits[$0].time >= options.start && (!options.kickOnly || hits[$0].kind == .kick) }
    let selected = indices.map { hits[$0] }
    let selectedGains = indices.map { dynamicsGains?[$0] ?? 1 }
    let tempoSummary = bpm.map { String(format: " · ~%.0f bpm", $0) } ?? ""
    print("\(name) · \(timestamp(duration))\(tempoSummary) · kicks \(selected.filter { $0.kind == .kick }.count) · accents \(selected.filter { $0.kind == .accent }.count) · dynamics \(options.dynamics && !options.metronome ? "on" : "off") · following volume \(options.followVolume ? "on" : "off") · rest your fingertips lightly on the trackpad")
    let latency = engine.outputNode.presentationLatency
    print(String(format: "Output presentation latency: %.3f ms", latency * 1000))
    let startHost = hostTime(mach_absolute_time(), plus: 0.25)
    player.play(at: AVAudioTime(hostTime: startHost))
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        defer { done.signal() }
        let starts = selected.map { hostTime(startHost, plus: $0.time - options.start + latency + options.offsetMs / 1000) }
        for i in selected.indices {
            if stopRequested { break }
            let hitHost = starts[i]
            if Double(mach_absolute_time()) - Double(hitHost) > 0.020 * ticksPerSecond { continue }
            waitUntil(hitHost)
            if stopRequested { break }
            if Double(mach_absolute_time()) - Double(hitHost) > 0.020 * ticksPerSecond { continue }
            let cutoff = i + 1 < starts.count ? hostTime(starts[i + 1], plus: -voiceGap) : UInt64.max
            let master = options.level * selectedGains[i] * volume.gain
            guard volume.haptics.allowed, shouldActuate(effectiveLevel(master: master, dynamics: 1, volume: 1, shaping: hitShaping(selected[i]))) else { continue }
            state.fired(selected[i])
            voice(selected[i], master: master, cutoff: cutoff) { volume.haptics.allowed }
        }
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    let endHost = hostTime(startHost, plus: duration - options.start + latency + 0.3)
    while !stopRequested && mach_absolute_time() < endHost {
        let policy = volume.haptics
        if policy.allowed != wasAllowed {
            print("\nHaptics \(policy.allowed ? "resumed" : "paused — " + (policy.reason ?? "output unavailable"))")
            wasAllowed = policy.allowed
        }
        let elapsed = max(0, (Double(mach_absolute_time()) - Double(startHost)) / ticksPerSecond - latency)
        let live = state.snapshot()
        print("\r▶ \(timestamp(min(duration, options.start + elapsed))) / \(timestamp(duration))   kicks \(live.kicks)  accents \(live.accents)   \(live.flash)   ", terminator: "")
        fflush(stdout)
        usleep(50_000)
    }
    state.stop()
    player.stop(); engine.stop()
    // The worker must finish before the actuator is closed, even on Ctrl-C.
    done.wait()
}

