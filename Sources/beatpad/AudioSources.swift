import AppKit
import CoreAudio
import Foundation

@available(macOS 14.2, *)
struct AudioProcess {
    let id: AudioObjectID
    let pid: pid_t
    let bundle: String
    let name: String
    let playing: Bool
}

@available(macOS 14.2, *)
func audioProcesses() throws -> [AudioProcess] {
    try audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { id in
        let pid = try audioProperty(id, kAudioProcessPropertyPID, pid_t(0))
        let bundle = (try? audioString(id, kAudioProcessPropertyBundleID)) ?? ""
        let app = NSRunningApplication(processIdentifier: pid)
        let playing = try audioProperty(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0
        return AudioProcess(id: id, pid: pid, bundle: bundle,
                            name: app?.localizedName ?? (bundle.isEmpty ? "Unknown app" : bundle), playing: playing)
    }.sorted { a, b in
        if a.playing != b.playing { return a.playing }
        if a.name != b.name { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        return a.pid < b.pid
    }
}

// Exact application identities take precedence over helper bundle prefixes.
func audioAppIndex(bundle: String, pid: pid_t, apps: [(bundle: String, pid: pid_t)]) -> Int? {
    let bundle = bundle.lowercased()
    if let exact = apps.indices.first(where: { apps[$0].pid == pid }) { return exact }
    if !bundle.isEmpty, let exact = apps.indices.first(where: { apps[$0].bundle.lowercased() == bundle }) { return exact }
    return apps.indices.filter {
        !apps[$0].bundle.isEmpty && bundle.hasPrefix(apps[$0].bundle.lowercased() + ".")
    }.max { apps[$0].bundle.count < apps[$1].bundle.count }
}

@available(macOS 14.2, *)
func listAudioApps(all: Bool = false) throws {
    print("App · Bundle ID · PID · Outputting now")
    let processes = try audioProcesses()
    if all {
        for p in processes { print("\(p.name) · \(p.bundle) · \(p.pid) · \(p.playing ? "yes" : "no")") }
        if processes.isEmpty { print("No audio processes available.") }
        return
    }
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil }
    let identities = apps.map { (bundle: $0.bundleIdentifier!, pid: $0.processIdentifier) }
    var groups: [String: (name: String, bundle: String, pids: Set<pid_t>)] = [:]
    for p in processes where p.playing && !(p.name == "Unknown app" && p.bundle.isEmpty) {
        let app = audioAppIndex(bundle: p.bundle, pid: p.pid, apps: identities).map { apps[$0] }
        let bundle = app?.bundleIdentifier ?? p.bundle
        let name = app?.localizedName ?? p.name
        let key = bundle.isEmpty ? name : bundle.lowercased()
        var group = groups[key] ?? (name, bundle, [])
        group.pids.insert(p.pid); groups[key] = group
    }
    for group in groups.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
        print("\(group.name) · \(group.bundle) · \(group.pids.sorted().map(String.init).joined(separator: ", ")) · yes")
    }
    if groups.isEmpty { print("Nothing is playing audio. Start playback, then run --list-apps again.") }
}

@available(macOS 14.2, *)
func matchAudioApp(_ query: String) throws -> (ids: [AudioObjectID], label: String) {
    let query = query.lowercased()
    let apps = NSWorkspace.shared.runningApplications
    let exact = apps.filter { $0.localizedName?.lowercased() == query }
    let prefix = apps.filter { $0.localizedName?.lowercased().hasPrefix(query) == true }
    let contains = apps.filter { $0.localizedName?.lowercased().contains(query) == true }
    let names = !exact.isEmpty ? exact : (!prefix.isEmpty ? prefix : contains)
    let bundles = apps.filter {
        guard let bundle = $0.bundleIdentifier?.lowercased() else { return false }
        return bundle == query || bundle.hasPrefix(query + ".")
    }
    let matched = names + bundles
    let pids = Set(matched.map { $0.processIdentifier })
    let bundleIDs = Set(matched.compactMap { $0.bundleIdentifier?.lowercased() })
    let processes = try audioProcesses()
    let selected = processes.filter { p in
        pids.contains(p.pid) || bundleIDs.contains { p.bundle.lowercased().hasPrefix($0 + ".") }
    }
    guard !matched.isEmpty, selected.contains(where: { $0.playing }) else {
        let playing = processes.filter { $0.playing }.map { "\($0.name) (\($0.bundle), PID \($0.pid))" }
        throw CaptureError(description: "No playing audio matched '\(query)'. Apps currently playing audio:\n" +
                           (playing.isEmpty ? "  none" : playing.map { "  " + $0 }.joined(separator: "\n")))
    }
    return (selected.map { $0.id }, matched.first?.localizedName ?? query)
}

struct InputDevice {
    let id: AudioObjectID
    let name: String
    let uid: String
    let channels: Int
}

func inputDevices() throws -> [InputDevice] {
    let devices = try audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    var inputs: [InputDevice] = []
    for id in devices {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioDevicePropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try captureCheck(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "read input channel layout size")
        guard size >= MemoryLayout<AudioBufferList>.size else { continue }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try captureCheck(AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage), "read input channel layout")
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        if channels > 0 {
            inputs.append(InputDevice(id: id, name: try audioString(id, kAudioObjectPropertyName),
                                      uid: try audioString(id, kAudioDevicePropertyDeviceUID), channels: channels))
        }
    }
    return inputs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func listInputs() throws {
    print("Input device · UID · Channels")
    let devices = try inputDevices()
    for d in devices { print("\(d.name) · \(d.uid) · \(d.channels)") }
    if devices.isEmpty { print("No input devices available.") }
}

func selectInput(_ query: String) throws -> InputDevice {
    let devices = try inputDevices()
    if query.isEmpty {
        let id = try audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0))
        if let device = devices.first(where: { $0.id == id }) { return device }
    } else {
        if let device = devices.first(where: { $0.uid == query }) { return device }
        if let device = devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) { return device }
    }
    throw CaptureError(description: "No input device matched. Use --input-list to see available inputs.")
}

let microphoneHint = "Heard only silence. System Settings → Privacy & Security → Microphone → enable your terminal app."
