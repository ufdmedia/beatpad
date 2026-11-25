import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

final class LiveRuntime: @unchecked Sendable {
    let input: LiveInputRing
    private let tracker: LiveTracker
    private let melody: LiveMelody?
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private let mapping: Double, options: Options
    private let volume: OutputVolume
    private var lastIntensity = 0.0
    init(rate: Double, latency: Double, options: Options, volume: OutputVolume) throws {
        self.volume = volume
        input = LiveInputRing(rate: rate)
        melody = try options.melody ? LiveMelody(sampleRate: rate) : nil
        tracker = try LiveTracker(sampleRate: rate, sensitivity: options.sensitivity, forcedBpm: options.bpm, dynamicsEnabled: options.dynamics, dynamicsRange: options.dynamicsRange)
        mapping = latency + options.offsetMs / 1000; self.options = options
    }
    private func audioIsFresh(at time: Double) -> Bool {
        let generation = tracker.resetGeneration
        let fresh = tracker.audioIsFresh(at: time)
        if tracker.resetGeneration != generation { melody?.reset() }
        return fresh
    }
    func start() {
        workers.enter()
        DispatchQueue(label: "beatpad.analysis", qos: .userInteractive).async {
            defer { self.workers.leave() }
            while !stopRequested {
                if let chunk = self.input.drain() {
                    self.lock.lock()
                    chunk.samples.withUnsafeBufferPointer {
                        let generation = self.tracker.resetGeneration
                        self.tracker.ingest($0, firstSampleTime: chunk.time)
                        if self.tracker.resetGeneration != generation { self.melody?.reset() }
                        self.melody?.ingest($0, firstSampleTime: chunk.time)
                    }
                    self.lock.unlock()
                } else { usleep(2000) }
            }
        }
        workers.enter()
        DispatchQueue(label: "beatpad.haptics", qos: .userInteractive).async {
            defer { self.workers.leave() }
            var scheduler = LiveHapticScheduler(melodyOnly: self.options.melodyOnly, kickOnly: self.options.kickOnly)
            while !stopRequested {
                let now = Double(mach_absolute_time()) / ticksPerSecond
                let audioNow = now - self.mapping
                self.lock.lock()
                let audioFresh = self.audioIsFresh(at: now)
                let p = self.tracker.beatPeriod
                let planned = audioFresh ? self.tracker.plan(after: max(scheduler.lastBeat - self.mapping + 0.25 * p, audioNow - 0.020)) : nil
                let beat = planned.map { PlannedBeat(time: $0.time + self.mapping, kind: $0.kind, strength: $0.strength) }
                let dynamicsGain = self.tracker.dynamicsGain
                let detected = self.melody?.current ?? (time: audioNow, hz: nil, strength: 0)
                self.lock.unlock()
                // Stale capture must not sustain the last note indefinitely.
                let fresh = audioFresh && audioNow - detected.time <= 0.100
                let melody: MelodyFrame = (detected.time, fresh ? detected.hz.map { $0 * pow(2, Double(self.options.melodyOctave)) } : nil,
                    self.options.level * self.options.melodyLevel * detected.strength * dynamicsGain * self.volume.gain)
                switch scheduler.nextAction(now: now, nextBeat: beat, melody: melody, allowed: self.volume.haptics.allowed) {
                case .wait(let until):
                    waitUntil(hostTime(0, plus: until), spinMargin: 0)
                case .playMelody(let hz, let duration, let level):
                    self.lock.lock()
                    let stillFresh = self.audioIsFresh(at: Double(mach_absolute_time()) / ticksPerSecond)
                    self.lock.unlock()
                    guard stillFresh, self.volume.haptics.allowed, !stopRequested else {
                        scheduler.thumpFinished(at: Double(mach_absolute_time()) / ticksPerSecond)
                        continue
                    }
                    let start = mach_absolute_time()
                    play([(hz, 1)], ms: duration * 1000, level: Float(level))
                    waitUntil(hostTime(start, plus: duration), spinMargin: 0.0003)
                case .fireThump(let beat, let fire):
                    waitUntil(hostTime(0, plus: fire))
                    if stopRequested { break }
                    self.lock.lock()
                    guard self.audioIsFresh(at: Double(mach_absolute_time()) / ticksPerSecond) else {
                        self.lock.unlock()
                        scheduler.thumpFinished(at: Double(mach_absolute_time()) / ticksPerSecond)
                        continue
                    }
                    let dynamicsGain = self.tracker.dynamicsGain
                    let next = self.tracker.plan(after: beat.time - self.mapping + 0.25 * p)
                    self.lock.unlock()
                    let cutoff = min(fire + 0.25, (next?.time).map { $0 + self.mapping - 0.002 } ?? fire + 0.25)
                    let hit = Hit(time: beat.time - self.mapping, kind: beat.kind!, strength: beat.strength)
                    let master = self.options.level * dynamicsGain * self.volume.gain
                    let intensity = effectiveLevel(master: master, dynamics: 1, volume: 1, shaping: hitShaping(hit))
                    guard self.volume.haptics.allowed, shouldActuate(intensity) else {
                        scheduler.thumpFinished(at: Double(mach_absolute_time()) / ticksPerSecond)
                        continue
                    }
                    self.lock.lock(); self.lastIntensity = intensity; self.lock.unlock()
                    state.fired(hit)
                    voice(hit, master: master, cutoff: hostTime(0, plus: cutoff)) {
                        self.lock.lock(); defer { self.lock.unlock() }
                        return self.volume.haptics.allowed && self.audioIsFresh(at: Double(mach_absolute_time()) / ticksPerSecond)
                    }
                    scheduler.thumpFinished(at: Double(mach_absolute_time()) / ticksPerSecond)
                }
            }
        }
    }
    func display() -> (String, Double, Double) {
        lock.lock(); defer { lock.unlock() }
        return (tracker.status.text + (options.melody ? " · ♪ \(melodyNote(melody?.current.hz))" : ""), decibels(tracker.rms), lastIntensity)
    }
    func finish() {
        state.stop(); workers.wait()
    }
    func summary() {
        let hits = state.snapshot()
        print(String(format: "Live totals: thumps %d ticks %d · relocks %d · mean |phase correction| %.3f ms",
                     hits.kicks, hits.accents, tracker.relocks,
                     tracker.correctionCount > 0 ? tracker.correctionTotal / Double(tracker.correctionCount) * 1000 : 0))
    }
}

@available(macOS 14.2, *)
func listen(options: Options) {
    let volume = OutputVolume(following: options.followVolume, anyOutput: options.anyOutput, externalTrackpad: options.external)
    var tap: AudioObjectID = 0, aggregate: AudioObjectID = 0, captureDevice: AudioObjectID = 0
    var proc: AudioDeviceIOProcID?
    var started = false
    var problem: String?
    var format = AudioStreamBasicDescription()
    var meter: CaptureMeter?
    var live: LiveRuntime?
    var latency = 0.0
    var latencySummary = "output latency unavailable (setup incomplete)"
    var label = "System audio"
    var aggregateDictionary: [String: Any] = [:]
    var outputUID = ""
    var outputInputStreams = 0
    var composed = ProcessInfo.processInfo.environment["BEATPAD_AGGREGATE"] == "composed"
    var enabledStreams: [Bool]?
    func prepareRuntime() throws {
        guard format.mSampleRate.isFinite, format.mSampleRate > 320 else {
            throw CaptureError(description: "Capture sample rate is not supported.")
        }
        try LiveTracker.validateTempo(options.bpm, sampleRate: format.mSampleRate)
        if options.live {
            live = try LiveRuntime(rate: format.mSampleRate, latency: latency, options: options, volume: volume)
        }
    }
    let isInput = options.input != nil
    if !isInput && options.app == nil {
        print("Listening to all system audio — use --app or --input to choose a source.")
    }
    if isInput && options.melody {
        print("Warning: the microphone can hear the trackpad's own melody tones.")
    }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { state.stop() }; source.resume(); return source
    }
    if options.live {
        preferExternal = options.external
        motor = openMotor(); motorPointer = Unmanaged.passUnretained(motor!).toOpaque()
        motorPolicy = volume.snapshot
    }
    volume.start(externalTrackpad: options.live ? !motorBuiltIn : options.external)
    defer { volume.stop() }
    if options.live, let reason = volume.haptics.reason { print("Haptics paused — \(reason)") }
    do {
        if let input = options.input {
            let device = try selectInput(input)
            label = device.name; captureDevice = device.id
            format = try audioProperty(device.id, kAudioDevicePropertyStreamFormat, AudioStreamBasicDescription(),
                                       scope: kAudioDevicePropertyScopeInput)
            try prepareRuntime()
        } else {
            let desc: CATapDescription
            if let app = options.app {
                let match = try matchAudioApp(app)
                label = match.label
                desc = CATapDescription(stereoMixdownOfProcesses: match.ids)
            } else {
                desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            }
            let output = try audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
            outputUID = try audioString(output, kAudioDevicePropertyDeviceUID)
            let scope = kAudioObjectPropertyScopeOutput
            let device = try audioProperty(output, kAudioDevicePropertyLatency, UInt32(0), scope: scope)
            let safety = try audioProperty(output, kAudioDevicePropertySafetyOffset, UInt32(0), scope: scope)
            let streams = try audioObjects(output, kAudioDevicePropertyStreams, scope: scope)
            guard let streamID = streams.first else { throw CaptureError(description: "Default output device has no output stream.") }
            let stream = try audioProperty(streamID, kAudioStreamPropertyLatency, UInt32(0))
            let buffer = try audioProperty(output, kAudioDevicePropertyBufferFrameSize, UInt32(0))
            let rate = try audioProperty(output, kAudioDevicePropertyNominalSampleRate, Float64(0))
            guard rate > 0 else { throw CaptureError(description: "Default output device has no nominal sample rate.") }
            latency = (Double(device) + Double(safety) + Double(stream) + Double(buffer)) / rate
            latencySummary = String(format: "output latency ~%.1f ms (device %u + safety %u + stream %u + buffer %u frames @ %.0f Hz)",
                                    (Double(device) + Double(safety) + Double(stream) + Double(buffer)) / rate * 1000, device, safety, stream, buffer, rate)
            outputInputStreams = try audioObjects(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
            format.mSampleRate = rate
            try prepareRuntime()
            desc.uuid = UUID(); desc.muteBehavior = .unmuted; desc.isPrivate = true
            try captureCheck(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
            guard tap != kAudioObjectUnknown else {
                throw CaptureError(description: "Couldn't create the audio tap (Core Audio returned no tap).")
            }
            let preparedRate = format.mSampleRate
            format = try audioProperty(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            if format.mSampleRate != preparedRate {
                try prepareRuntime()
            }
            let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            print("Tap format: \(format.mSampleRate) Hz · \(format.mChannelsPerFrame)ch · float \(floating) · interleaved \(interleaved)")
            guard format.mFormatID == kAudioFormatLinearPCM, floating, format.mBitsPerChannel == 32,
                  format.mSampleRate > 320, format.mChannelsPerFrame > 0,
                  format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
                throw CaptureError(description: "Tap format is not supported: native-endian Float32 PCM required.")
            }
            aggregateDictionary = [
                kAudioAggregateDeviceNameKey: "beatpad tap", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]
            ]
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mSampleRate > 320, format.mChannelsPerFrame > 0 else {
            throw CaptureError(description: "Capture format is not supported: native-endian Float32 PCM required.")
        }
        if isInput { latencySummary = "input source: speaker mapping K = 0 ms" }
        let accumulator = CaptureMeter(sampleRate: format.mSampleRate); meter = accumulator
        let runtime = live
        if options.live { print(latencySummary) }
        let queue = DispatchQueue(label: "beatpad.capture", qos: .userInteractive)
        func startCapture() throws {
            if !isInput {
                var dictionary = aggregateDictionary
                dictionary[kAudioAggregateDeviceUIDKey] = UUID().uuidString
                if composed {
                    dictionary[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
                    dictionary[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
                }
                try captureCheck(AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
                captureDevice = aggregate
            }
            try captureCheck(AudioDeviceCreateIOProcIDWithBlock(&proc, captureDevice, queue) { _, input, inputTime, _, _ in
                let entry = mach_absolute_time()
                if let runtime { runtime.input.consume(input, time: inputTime, enabledStreams: enabledStreams) }
                if runtime == nil || isInput { accumulator.consume(input, time: inputTime, entry: entry, enabledStreams: enabledStreams) }
            }, "AudioDeviceCreateIOProcIDWithBlock")
            if !isInput {
                enabledStreams = try configureTapStreams(aggregate, proc: proc!, disabledCount: composed ? outputInputStreams : 0,
                                                         tapChannels: Int(format.mChannelsPerFrame))
            }
            try captureCheck(AudioDeviceStart(captureDevice, proc), "AudioDeviceStart")
            started = true
        }
        do { try startCapture() }
        catch {
            if isInput || composed { throw error }
            if let oldProc = proc {
                try captureCheck(AudioDeviceDestroyIOProcID(captureDevice, oldProc), "destroy tap-only IOProc")
                proc = nil
            }
            if aggregate != 0 {
                try captureCheck(AudioHardwareDestroyAggregateDevice(aggregate), "destroy tap-only aggregate")
                aggregate = 0
            }
            composed = true; enabledStreams = nil
            try startCapture()
        }
        if !isInput { print("Capture path: \(composed ? "composed (output inputs disabled)" : "tap-only")") }
        runtime?.start()
        let start = now()
        var lastNonzero = start, microphoneWarned = false
        while !stopRequested && (options.seconds == nil || now() - start < options.seconds!) {
            if isInput {
                let stats = accumulator.snapshot(resetWindow: runtime != nil)
                if stats.windowPeak > 0 { lastNonzero = now() }
                if !microphoneWarned && now() - lastNonzero >= 3 {
                    print("\n" + microphoneHint); microphoneWarned = true
                }
            }
            if let runtime {
                let (trackingStatus, db, intensity) = runtime.display(), hits = state.snapshot()
                let waitingStatus = options.app == nil && options.input == nil ? "waiting for system audio…" : "waiting for \(label) audio…"
                let policy = volume.haptics
                let status = !policy.allowed ? "paused — \(policy.reason ?? "output unavailable")" :
                    (runtime.input.callbackAge > liveNoCallbackSeconds ? waitingStatus : trackingStatus)
                print("\r◉ \(label) · \(status) · \(hits.flash) · thumps \(hits.kicks) ticks \(hits.accents) · level \(levelBar(db, cells: 8)) · int \(String(repeating: "▇", count: Int((intensity * 5).rounded())))\(String(repeating: "▁", count: 5 - Int((intensity * 5).rounded()))) \(Int((intensity * 100).rounded()))% · \(timestamp(now() - start))   ", terminator: "")
                fflush(stdout); usleep(50_000); continue
            }
            let stats = accumulator.snapshot(resetWindow: true)
            let count = Double(max(1, stats.windowFrames))
            let db = decibels(sqrt(stats.energy / count)), lowDB = decibels(sqrt(stats.lowEnergy / count))
            print(String(format: "\r◉ %@ · %.0f Hz %uch · level %@ %.0f dB · low %@ · %@   ", label,
                         format.mSampleRate, format.mChannelsPerFrame, levelBar(db, cells: 8), db,
                         levelBar(lowDB, cells: 5), timestamp(now() - start)), terminator: "")
            fflush(stdout); usleep(50_000)
        }
        print("")
    } catch { problem = String(describing: error) }
    live?.finish()
    // Try every teardown step, even if an earlier teardown step fails.
    func cleanupStatus(_ status: OSStatus, _ step: String) {
        if status != noErr {
            let message = statusMessage(step, status)
            problem = problem.map { $0 + "\n" + message } ?? message
        }
    }
    if started { cleanupStatus(AudioDeviceStop(captureDevice, proc), "AudioDeviceStop") }
    if let proc { cleanupStatus(AudioDeviceDestroyIOProcID(captureDevice, proc), "AudioDeviceDestroyIOProcID") }
    if aggregate != 0 { cleanupStatus(AudioHardwareDestroyAggregateDevice(aggregate), "AudioHardwareDestroyAggregateDevice") }
    if tap != 0 { cleanupStatus(AudioHardwareDestroyProcessTap(tap), "AudioHardwareDestroyProcessTap") }
    if let motor { _ = actuatorClose?(motor) }
    motorPointer = nil; motor = nil
    for source in signals { source.cancel() }
    if options.live {
        live?.summary()
        if let problem { volume.stop(); fail(problem, headline: "beatpad couldn't capture audio.") }
        return
    }
    volume.refresh()
    print(volume.summary)
    print(volume.hapticsSummary)
    let stats = meter?.snapshot() ?? CaptureTotals()
    if stats.callbacks == 0 {
        print("Heard nothing — \(label) is paused or not playing yet.")
        if let problem { volume.stop(); fail(problem, headline: "beatpad couldn't capture audio.") }
        return
    }
    let bufferMS = format.mSampleRate > 0 ? Double(stats.lastFrames) / format.mSampleRate * 1000 : 0
    let interval = stats.intervalCount > 0 ? String(format: "%.1f ms (max %.1f)", stats.intervalSum / Double(stats.intervalCount), stats.intervalMax) : "unavailable"
    print(String(format: "callbacks %d · buffer %d frames (%.1f ms) · callback interval mean %@", stats.callbacks, stats.lastFrames, bufferMS, interval))
    if stats.staleCount > 0 {
        print(String(format: "input staleness mean %.1f ms (max %.1f)", stats.staleSum / Double(stats.staleCount), stats.staleMax))
    } else { print("input staleness unavailable (no valid input host timestamps)") }
    let silent = stats.callbacks > 0 ? Double(stats.silent) / Double(stats.callbacks) * 100 : 0
    print(String(format: "silent callbacks %.1f %%  (peak < 1e-6)", silent))
    print(String(format: "peak level %.1f dBFS", decibels(stats.peak)))
    print(latencySummary)
    if silent > 95 {
        if !isInput { print("Heard only silence. Start audio and allow this terminal app in System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then quit and reopen it.") }
    }
    fflush(stdout)
    if let problem { volume.stop(); fail(problem, headline: "beatpad couldn't capture audio.") }
}

