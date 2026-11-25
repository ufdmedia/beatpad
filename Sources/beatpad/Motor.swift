// Adapted from nospeaker by Cody Collier (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - The haptic motor (MultitouchSupport, resolved at run time)

let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mt, let p = dlsym(mt, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

let createList = sym("MTDeviceCreateList", CreateList.self)
let getID = sym("MTDeviceGetDeviceID", GetID.self)
let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
let actuatorClose = sym("MTActuatorClose", ActuatorClose.self)
let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)

var deviceCount = 0
var motorDeviceID: UInt64 = 0
var motorBuiltIn = false
var deviceList: CFArray?
/// --external: play through an external Magic Trackpad instead of the built-in trackpad.
var preferExternal = false

/// The Mac's model identifier, like "MacBookPro18,3" or "Mac14,3".
func macModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(1, size))
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}
func laptop() -> Bool {
    if macModel().hasPrefix("MacBook") { return true }
    let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    if battery != 0 { IOObjectRelease(battery); return true }
    return false
}

/// Explains, in plain words, why there's no trackpad to play, and what would fix it.
func noTrackpad(_ found: Bool) -> Never {
    let message: String
    if !found && !laptop() {
        message = """
        This Mac doesn't have a built-in trackpad, and no trackpad is connected.
        Connect a Magic Trackpad (2 or newer, the ones with Force Touch) and run it again.
        """
    } else if !found {
        message = "No trackpad was found. Make sure the trackpad is on and connected, then run it again."
    } else {
        message = """
        Found a trackpad, but it doesn't have a haptic motor (Force Touch), so it can't make felt beats.
        It needs a MacBook from 2015 or later, or a Magic Trackpad 2 or newer.
        """
    }
    fail(message)
}

func openMotor() -> CFTypeRef {
    guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuatorClose != nil, isBuiltIn != nil, actuationCreate != nil, actuationPlay != nil else {
        fail("This version of macOS doesn't have the trackpad functions this needs. It requires macOS 13+; live capture requires macOS 14.2+.")
    }
    guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { noTrackpad(false) }
    deviceList = list
    var ids: [(id: UInt64, builtIn: Bool)] = []
    for i in 0..<CFArrayGetCount(list) {
        guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
        let dev = UnsafeMutableRawPointer(mutating: raw)
        var id: UInt64 = 0
        if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
    }
    deviceCount = ids.count
    // --external: play only through an external trackpad (a Magic Trackpad), never the built-in one.
    if preferExternal {
        for d in ids where !d.builtIn {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                motorDeviceID = d.id
                motorBuiltIn = d.builtIn
                return ref
            }
        }
        fail("""
        --external was given, but no external trackpad was found.
        Turn on your Magic Trackpad (2 or newer, the ones with Force Touch), connect it, and run it again.
        """)
    }
    for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
        if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
            motorDeviceID = d.id
            motorBuiltIn = d.builtIn
            return ref
        }
    }
    noTrackpad(true)
}

var motorPolicy = PolicySnapshot()
var motor: CFTypeRef?
var motorPointer: UnsafeMutableRawPointer?

/// Plays tones (Hz, relative strength) together for `ms` at overall `level` (0…1). Strengths are scaled to
/// add up to 1: past that is louder, but the driver starts stalling on long runs.
func play(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float,
          policy: PolicySnapshot? = nil, actuationHook: (() -> Void)? = nil) {
    let snapshot = policy ?? motorPolicy
    guard !tones.isEmpty else { return }
    var act: UnsafeMutableRawPointer?
    let actuate: () -> Void
    if let actuationHook {
        actuate = actuationHook
    } else {
        guard let motorPointer else { return }
        let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
        let shape: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
            "Tones": tones.map { ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000] },
        ]
        guard let created = actuationCreate!(shape as CFDictionary, 0) else { return }
        act = created
        actuate = { _ = actuationPlay!(created, motorPointer, 0, min(1, max(0, level)), 0) }
    }
    defer { if let act { Unmanaged<AnyObject>.fromOpaque(act).release() } }
    // Check after preparing the burst, immediately before submitting it to the actuator.
    snapshot.submit(actuate)
}

func voice(_ hit: Hit, master: Double, cutoff: UInt64, canActuate: () -> Bool = { true }) {
    let start = mach_absolute_time()
    let duration = hit.kind == .kick ? kickDuration : accentDuration
    var t = 0.0
    while t < duration && !stopRequested && mach_absolute_time() < cutoff && canActuate() {
        let f: Double, envelope: Double, gain: Double
        switch hit.kind {
        case .kick:
            f = kickFloorHz + kickDiveHz * exp(-t / kickDiveDecay)
            envelope = exp(-t / kickEnvelopeDecay)
            gain = kickBaseLevel + kickStrengthLevel * hit.strength
        case .accent:
            f = accentHz
            envelope = exp(-t / accentEnvelopeDecay)
            gain = accentBaseLevel + accentStrengthLevel * hit.strength
        }
        let seg = 1 / f
        // Don't submit a cycle that would keep actuating past the next hit's cutoff.
        if hostTime(start, plus: t + seg) > cutoff { break }
        let level = min(1, max(0, master * gain * envelope))
        if shouldActuate(level) { play([(f, 1)], ms: seg * 1000, level: Float(level)) }
        t += seg
        waitUntil(hostTime(start, plus: t))
    }
}
