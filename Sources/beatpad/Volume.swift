import Foundation
import IOKit
import CoreAudio

enum LidState { case open, closed, unknown }
enum PropertyRead<T> { case value(T), absent, failed }
typealias HapticsDecision = (allowed: Bool, reason: String?)

func hapticsAllowed(outputTransport: UInt32?, outputDataSource: PropertyRead<UInt32>, outputName: String,
                    lid: LidState, anyOutput: Bool, externalTrackpad: Bool) -> HapticsDecision {
    if externalTrackpad { return (true, nil) }
    switch lid {
    case .closed: return (false, "lid closed")
    case .unknown: return (false, "lid state unavailable")
    case .open: break
    }
    guard let transport = outputTransport else { return (false, "couldn't read the output route") }
    if case .failed = outputDataSource { return (false, "couldn't read the output route") }
    if anyOutput { return (true, nil) }
    let speakers: Bool
    switch outputDataSource {
    case .value(let value): speakers = value == 0x6973706b
    case .absent:
        let name = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers = name.range(of: "^((macbook( pro| air)?|imac|mac( mini| studio| pro)?|built-in|internal) )?speakers$",
                              options: [.regularExpression, .caseInsensitive]) != nil
    case .failed: speakers = false
    }
    if transport == kAudioDeviceTransportTypeBuiltIn && speakers { return (true, nil) }
    return (false, "sound is going to \"\(outputName)\"; the trackpad only runs on the built-in speakers (use --any-output to allow)")
}

private func readLid() -> LidState {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return .unknown }
    defer { IOObjectRelease(root) }
    guard let closed = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool else { return .unknown }
    return closed ? .closed : .open
}

// The generation prevents a route notification from being overwritten by an in-flight read.
final class PolicySnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> Double
    private var time = -Double.infinity, generation = 0
    private var external = false, stopped = false
    private var decision: HapticsDecision = (false, "output not checked yet")
    init(clock: @escaping () -> Double = now) { self.clock = clock }
    var version: Int { lock.lock(); defer { lock.unlock() }; return generation }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard !external && !stopped else { return }
        generation += 1; time = clock(); decision = (false, "output route changed")
    }
    func publish(_ value: HapticsDecision, startedAt: Double, version: Int) {
        lock.lock(); defer { lock.unlock() }
        guard version == generation && !external && !stopped else { return }
        time = startedAt; decision = value
    }
    func configure(externalTrackpad: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation += 1; external = externalTrackpad; stopped = false
        time = -Double.infinity; decision = (false, "output not checked yet")
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation += 1; stopped = true
    }
    private func checked() -> HapticsDecision {
        if stopped { return (false, "output monitor stopped") }
        if external { return (true, nil) }
        guard clock() - time <= 1 else { return (false, "output check stalled") }
        return decision
    }
    var current: HapticsDecision {
        lock.lock(); defer { lock.unlock() }
        return checked()
    }
    // The closure only submits the prepared burst; it must not reenter this snapshot.
    func submit(_ actuate: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard checked().allowed else { return }
        actuate()
    }
}

struct OutputObservation {
    var device: AudioObjectID
    var transport: UInt32?
    var dataSource: PropertyRead<UInt32>
    var name: String
    var scalar: Double? = nil
    var muted: Bool? = nil
}

// All hardware reads and listener lifecycle operations run on the monitor queue.
final class OutputVolume: @unchecked Sendable {
    let snapshot: PolicySnapshot
    private let clock: () -> Double
    private let lidReader: () -> LidState
    private let routeReader: (() -> OutputObservation)?
    private let install: (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    private let uninstall: (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    private let automatic: Bool
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "beatpad.output-policy", qos: .userInteractive)
    private let notificationQueue = DispatchQueue(label: "beatpad.output-changes", qos: .userInteractive)
    private var running = false
    private var timer: DispatchSourceTimer?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var device: AudioObjectID = 0
    private var scalar: Double?, muted: Bool?
    private var warned = false
    private let anyOutput: Bool
    private var externalTrackpad: Bool
    let following: Bool
    init(following: Bool, anyOutput: Bool = false, externalTrackpad: Bool = false,
         clock: @escaping () -> Double = now, lidReader: @escaping () -> LidState = readLid,
         routeReader: (() -> OutputObservation)? = nil, automatic: Bool = true,
         install: @escaping (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus = { object, address, queue, block in
             AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
         },
         uninstall: @escaping (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus = { object, address, queue, block in
             AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
         }) {
        self.following = following; self.anyOutput = anyOutput; self.externalTrackpad = externalTrackpad
        self.clock = clock; self.lidReader = lidReader; self.routeReader = routeReader
        self.automatic = automatic; self.install = install; self.uninstall = uninstall
        snapshot = PolicySnapshot(clock: clock)
    }
    func start(externalTrackpad: Bool) {
        queue.sync {
            running = true
            self.externalTrackpad = externalTrackpad
            snapshot.configure(externalTrackpad: externalTrackpad)
            evaluate()
            guard automatic else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + volumePollSeconds, repeating: volumePollSeconds, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.evaluate() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        snapshot.stop()
        queue.sync {
            running = false
            timer?.cancel(); timer = nil
            removeListeners()
            if !listeners.isEmpty {
                // Retain cleanup records until CoreAudio accepts every removal.
                let cleanup = DispatchSource.makeTimerSource(queue: queue)
                cleanup.schedule(deadline: .now() + volumePollSeconds, repeating: volumePollSeconds)
                cleanup.setEventHandler {
                    self.removeListeners()
                    if self.listeners.isEmpty { self.timer?.cancel(); self.timer = nil }
                }
                timer = cleanup; cleanup.resume()
            }
        }
    }
    private func removeListeners(deviceOnly: Bool = false) {
        listeners.removeAll { object, address, block in
            if deviceOnly && (object == AudioObjectID(kAudioObjectSystemObject) || object == device) { return false }
            var address = address
            let status = uninstall(object, &address, notificationQueue, block)
            return status == noErr || status == kAudioHardwareBadObjectError
        }
    }
    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) -> Bool {
        if listeners.contains(where: { $0.0 == object && $0.1.mSelector == selector && $0.1.mScope == scope }) { return true }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            let relevant = object == AudioObjectID(kAudioObjectSystemObject) || object == self.device
            if relevant { self.snapshot.invalidate() }
            self.lock.unlock()
            if relevant { self.queue.async { [weak self] in self?.evaluate() } }
        }
        guard install(object, &address, notificationQueue, block) == noErr else { return false }
        listeners.append((object, address, block)); return true
    }
    private func read<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, initial: T) -> PropertyRead<T> {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return .absent }
        var value = initial, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr && size == MemoryLayout<T>.size ? .value(value) : .failed
    }
    private func value<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, initial: T) -> T? {
        if case .value(let result) = read(device, selector, element: element, initial: initial) { return result }
        return nil
    }
    func refresh() { queue.sync { evaluate() } }
    private func evaluate() {
        guard running else { return }
        let version = snapshot.version, time = clock()
        let lidObservationTime = clock(), lid = lidReader()
        let observation = routeReader?() ?? readOutput()
        let current = observation.device
        lock.lock(); device = current; lock.unlock()
        removeListeners(deviceOnly: true)
        let systemOK = addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                   scope: kAudioObjectPropertyScopeGlobal)
        var sourceOK = true, transportOK = false
        if current != 0 {
            if case .absent = observation.dataSource {} else {
                sourceOK = addListener(current, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
            }
            transportOK = addListener(current, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        }
        let listenersReady = systemOK && sourceOK && transportOK
        lock.lock(); scalar = observation.scalar; muted = observation.muted; lock.unlock()
        let policy = hapticsAllowed(outputTransport: observation.transport, outputDataSource: observation.dataSource,
                                    outputName: observation.name, lid: lid, anyOutput: anyOutput, externalTrackpad: externalTrackpad)
        snapshot.publish(!listenersReady && !externalTrackpad ? (false, "couldn't read the output route") : policy,
                         startedAt: min(time, lidObservationTime), version: version)
        if following && (observation.scalar == nil || observation.muted == nil) && !warned {
            print("Output volume isn't readable on this device — not following volume."); warned = true
        }
    }
    private func readOutput() -> OutputObservation {
        var value: Double?, mute: Bool?
        var transport: UInt32?, dataSource = PropertyRead<UInt32>.failed, name = "unknown output"
        let current = (try? audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))) ?? 0
        if current != 0 {
            transport = try? audioProperty(current, kAudioDevicePropertyTransportType, UInt32(0))
            dataSource = read(current, kAudioDevicePropertyDataSource, initial: UInt32(0))
            if let outputName = try? audioString(current, kAudioObjectPropertyName) { name = outputName }
            else { transport = nil }
            if let main = self.value(current, kAudioDevicePropertyVolumeScalar, initial: Float32(0)) {
                value = Double(main)
            } else if let a = self.value(current, kAudioDevicePropertyVolumeScalar, element: 1, initial: Float32(0)),
                      let b = self.value(current, kAudioDevicePropertyVolumeScalar, element: 2, initial: Float32(0)) {
                value = (Double(a) + Double(b)) / 2
            }
            if let main = self.value(current, kAudioDevicePropertyMute, initial: UInt32(0)) {
                mute = main != 0
            } else if let a = self.value(current, kAudioDevicePropertyMute, element: 1, initial: UInt32(0)),
                      let b = self.value(current, kAudioDevicePropertyMute, element: 2, initial: UInt32(0)) {
                mute = a != 0 && b != 0
            }
        }
        if value?.isFinite != true { value = nil }
        return OutputObservation(device: current, transport: transport, dataSource: dataSource, name: name, scalar: value, muted: mute)
    }
    var haptics: HapticsDecision { snapshot.current }
    var hapticsSummary: String {
        let policy = haptics
        return "haptics would run: \(policy.allowed ? "yes" : "no") (\(policy.reason ?? "output policy allows haptics"))"
    }
    var gain: Double {
        guard following else { return 1 }
        lock.lock(); defer { lock.unlock() }
        return listeningVolumeGain(scalar: scalar, muted: muted)
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        guard let scalar, let muted else { return "output volume not readable" }
        return String(format: "output volume %.2f · muted %@", scalar, muted ? "yes" : "no")
    }
}

