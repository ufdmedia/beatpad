import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// Poll the default output again to follow device switches. Haptic workers read a small locked snapshot at commit time.
final class OutputVolume: @unchecked Sendable {
    private let lock = NSLock()
    private var scalar: Double?, muted: Bool?
    private var lastPoll = -Double.infinity, warned = false
    let following: Bool
    init(following: Bool) { self.following = following }
    private func read<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         element: AudioObjectPropertyElement, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = initial, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }
    func poll(force: Bool = false) {
        guard force || now() - lastPoll >= volumePollSeconds else { return }
        lastPoll = now()
        var value: Double?, mute: Bool?
        if let device = try? audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)), device != 0 {
            if let main = read(device, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain, initial: Float32(0)) {
                value = Double(main)
            } else if let a = read(device, kAudioDevicePropertyVolumeScalar, element: 1, initial: Float32(0)),
                      let b = read(device, kAudioDevicePropertyVolumeScalar, element: 2, initial: Float32(0)) {
                value = (Double(a) + Double(b)) / 2
            }
            if let main = read(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, initial: UInt32(0)) {
                mute = main != 0
            } else if let a = read(device, kAudioDevicePropertyMute, element: 1, initial: UInt32(0)),
                      let b = read(device, kAudioDevicePropertyMute, element: 2, initial: UInt32(0)) {
                mute = a != 0 && b != 0
            }
        }
        if value?.isFinite != true { value = nil }
        lock.lock(); scalar = value; muted = mute; lock.unlock()
        if following && (value == nil || mute == nil) && !warned {
            print("Output volume isn't readable on this device — not following volume.")
            warned = true
        }
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

