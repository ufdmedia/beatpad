import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Shared process-tap capture and live runtime

struct CaptureError: Error, CustomStringConvertible {
    let description: String
}
func statusMessage(_ step: String, _ status: OSStatus) -> String {
    let bits = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((bits >> $0) & 0xff) }
    let fourCC = bytes.allSatisfy { (32...126).contains($0) }
        ? " ('\(String(bytes: bytes, encoding: .ascii)!)')" : ""
    return "\(step): OSStatus \(status)\(fourCC)"
}
func captureCheck(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw CaptureError(description: statusMessage(step, status)) }
}
func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = initial, size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) {
        try captureCheck(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0), "read property \(selector) on \(object)")
    }
    return value
}
func audioObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try captureCheck(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "size property \(selector) on \(object)")
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    if size > 0 {
        try values.withUnsafeMutableBytes {
            try captureCheck(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!), "read property \(selector) on \(object)")
        }
    }
    return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}
func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    // Core Audio CF properties return an owned reference.
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    try captureCheck(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read string property \(selector) on \(object)")
    guard let value else { throw CaptureError(description: "Empty string property \(selector) on \(object)") }
    return value.takeRetainedValue() as String
}

struct CaptureTotals {
    var callbacks = 0, frames = 0, lastFrames = 0, silent = 0
    var intervalCount = 0, staleCount = 0
    var intervalSum = 0.0, intervalMax = 0.0, staleSum = 0.0, staleMax = -Double.infinity
    var peak = 0.0, windowPeak = 0.0
    var windowFrames = 0
    var energy = 0.0, lowEnergy = 0.0
}
final class CaptureMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var totals = CaptureTotals()
    private var previousHost: UInt64 = 0
    // Butterworth low-pass at 160 Hz, transposed direct form II. State lives only on the IO queue.
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0
    init(sampleRate: Double) {
        let k = tan(Double.pi * 160 / sampleRate)
        let norm = 1 / (1 + sqrt(2) * k + k * k)
        b0 = k * k * norm; b1 = 2 * b0; b2 = b0
        a1 = 2 * (k * k - 1) * norm; a2 = (1 - sqrt(2) * k + k * k) * norm
    }
    func consume(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, entry: UInt64, enabledStreams: [Bool]? = nil) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if let enabledStreams, enabledStreams.count != buffers.count { return }
        var frames = Int.max, channels = 0
        for (index, buffer) in buffers.enumerated() where (enabledStreams?[index] ?? true) && buffer.mNumberChannels > 0 && buffer.mData != nil {
            channels += Int(buffer.mNumberChannels)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }
        if channels == 0 || frames == Int.max { frames = 0 }
        var energy = 0.0, lowEnergy = 0.0, peak = 0.0
        for frame in 0..<frames {
            var mono = 0.0
            for (index, buffer) in buffers.enumerated() {
                guard enabledStreams?[index] ?? true else { continue }
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let count = Int(buffer.mNumberChannels)
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<count { mono += Double(samples[frame * count + channel]) }
            }
            mono /= Double(channels)
            let low = b0 * mono + z1
            z1 = b1 * mono - a1 * low + z2; z2 = b2 * mono - a2 * low
            energy += mono * mono; lowEnergy += low * low; peak = max(peak, abs(mono))
        }
        lock.lock(); defer { lock.unlock() }
        totals.callbacks += 1; totals.frames += frames; totals.lastFrames = frames
        totals.windowFrames += frames; totals.energy += energy; totals.lowEnergy += lowEnergy
        totals.peak = max(totals.peak, peak); totals.windowPeak = max(totals.windowPeak, peak)
        if peak < 1e-6 { totals.silent += 1 }
        if previousHost != 0 {
            let interval = (Double(entry) - Double(previousHost)) / ticksPerSecond * 1000
            totals.intervalCount += 1; totals.intervalSum += interval; totals.intervalMax = max(totals.intervalMax, interval)
        }
        previousHost = entry
        if time.pointee.mFlags.contains(.hostTimeValid) {
            let stale = (Double(entry) - Double(time.pointee.mHostTime)) / ticksPerSecond * 1000
            totals.staleCount += 1; totals.staleSum += stale; totals.staleMax = max(totals.staleMax, stale)
        }
    }
    func snapshot(resetWindow: Bool = false) -> CaptureTotals {
        lock.lock(); defer { lock.unlock() }
        let result = totals
        if resetWindow { totals.windowFrames = 0; totals.windowPeak = 0; totals.energy = 0; totals.lowEnergy = 0 }
        return result
    }
}
func decibels(_ amplitude: Double) -> Double { 20 * log10(max(amplitude, 1e-12)) }
func levelBar(_ db: Double, cells: Int) -> String {
    let filled = Int((min(1, max(0, (db + 60) / 60)) * Double(cells)).rounded())
    return String(repeating: "▇", count: filled) + String(repeating: "▁", count: cells - filled)
}

// The IO callback writes only preallocated storage. Analysis owns all allocations.
final class LiveInputRing: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float], times: [Double]
    private var drainBuffer = [Float](repeating: 0, count: 4096)
    private var read = 0, write = 0
    private var lastCallback: Double?
    private let createdAt = now()
    var callbackAge: Double {
        lock.lock(); defer { lock.unlock() }
        return now() - (lastCallback ?? createdAt)
    }
    private let rate: Double
    init(rate: Double) {
        self.rate = rate
        values = [Float](repeating: 0, count: Int(ceil(rate * 12)))
        times = [Double](repeating: 0, count: values.count)
    }
    func consume(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, enabledStreams: [Bool]? = nil) {
        lock.lock(); lastCallback = now(); lock.unlock()
        guard time.pointee.mFlags.contains(.hostTimeValid) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if let enabledStreams, enabledStreams.count != buffers.count { return }
        var frames = Int.max, channels = 0
        for (index, b) in buffers.enumerated() where (enabledStreams?[index] ?? true) && b.mData != nil && b.mNumberChannels > 0 {
            channels += Int(b.mNumberChannels)
            frames = min(frames, Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels)))
        }
        guard channels > 0, frames != Int.max else { return }
        let start = Double(time.pointee.mHostTime) / ticksPerSecond
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            var mono: Float = 0
            for (index, b) in buffers.enumerated() {
                guard enabledStreams?[index] ?? true else { continue }
                guard let data = b.mData, b.mNumberChannels > 0 else { continue }
                let count = Int(b.mNumberChannels), p = data.assumingMemoryBound(to: Float.self)
                for c in 0..<count { mono += p[i * count + c] }
            }
            values[write % values.count] = mono / Float(channels)
            times[write % values.count] = start + Double(i) / rate
            write += 1
            if write - read > values.count { read = write - values.count }
        }
    }
    func drain() -> (samples: [Float], time: Double)? {
        lock.lock()
        guard read < write else { lock.unlock(); return nil }
        let start = times[read % values.count]
        var count = 0
        // Preserve timestamp discontinuities instead of inventing continuous samples.
        while read < write && count < drainBuffer.count {
            if abs(times[read % values.count] - start - Double(count) / rate) > liveTimestampGap { break }
            drainBuffer[count] = values[read % values.count]; count += 1; read += 1
        }
        lock.unlock()
        return (drainBuffer.withUnsafeBufferPointer { Array($0.prefix(count)) }, start)
    }
}

// IOProc stream usage retains buffer positions, with NULL data for disabled streams.
func configureTapStreams(_ device: AudioObjectID, proc: AudioDeviceIOProcID,
                         disabledCount: Int, tapChannels: Int) throws -> [Bool] {
    let streams = try audioObjects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    guard disabledCount >= 0, disabledCount < streams.count else {
        throw CaptureError(description: "Aggregate has no isolated tap input streams.")
    }
    let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
    let byteCount = max(MemoryLayout<AudioHardwareIOProcStreamUsage>.size, offset + streams.count * MemoryLayout<UInt32>.size)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
    usage.pointee.mNumberStreams = UInt32(streams.count)
    let flags = storage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
    for i in streams.indices { flags[i] = i < disabledCount ? 0 : 1 }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    if disabledCount > 0 {
        try captureCheck(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(byteCount), storage), "disable output-device input streams")
    }
    var size = UInt32(byteCount)
    try captureCheck(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage), "read IOProc input stream usage")
    guard usage.pointee.mNumberStreams == streams.count else {
        throw CaptureError(description: "Aggregate input stream usage changed during setup.")
    }
    let enabled = streams.indices.map { flags[$0] != 0 }
    guard enabled.enumerated().allSatisfy({ $0.element == ($0.offset >= disabledCount) }) else {
        throw CaptureError(description: "Couldn't isolate tap streams from output-device inputs.")
    }
    address.mSelector = kAudioDevicePropertyStreamConfiguration
    size = 0
    try captureCheck(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "size aggregate input channel layout")
    guard size >= MemoryLayout<AudioBufferList>.size else {
        throw CaptureError(description: "Aggregate input channel layout is missing.")
    }
    let layout = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { layout.deallocate() }
    try captureCheck(AudioObjectGetPropertyData(device, &address, 0, nil, &size, layout), "read aggregate input channel layout")
    let buffers = UnsafeMutableAudioBufferListPointer(layout.assumingMemoryBound(to: AudioBufferList.self))
    guard buffers.count == enabled.count else {
        throw CaptureError(description: "Aggregate input layout doesn't match its stream usage; refusing unknown inputs.")
    }
    let channels = buffers.enumerated().reduce(0) { $0 + (enabled[$1.offset] ? Int($1.element.mNumberChannels) : 0) }
    guard channels == tapChannels else {
        throw CaptureError(description: "Aggregate enabled inputs have \(channels) channels; tap requires \(tapChannels). Refusing unknown inputs.")
    }
    return enabled
}
