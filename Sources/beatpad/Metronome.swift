import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

func metronome(bpm: Double) -> (buffer: AVAudioPCMBuffer, hits: [Hit]) {
    let sr = 48000.0, beat = 60 / bpm
    let duration = max(16 * beat, 15 * beat + 0.080)
    guard duration.isFinite, duration * sr < Double(UInt32.max) else { usageError("--bpm makes the metronome too long") }
    var samples = [Float](repeating: 0, count: Int(ceil(duration * sr)))
    var hits: [Hit] = []
    for i in 0..<16 {
        let start = Double(i) * beat, first = Int((start * sr).rounded())
        hits.append(Hit(time: start, kind: .kick, strength: i % 4 == 0 ? 1 : 0.7))
        for j in 0..<Int(0.080 * sr) where first + j < samples.count {
            let t = Double(j) / sr
            var value = 0.8 * sweep(t, duration: 0.080) * exp(-t / 0.030)
            if i % 4 == 0 && t < 0.020 { value += 0.3 * sin(2 * .pi * 2000 * t) }
            samples[first + j] += Float(value)
        }
    }
    return (pcmBuffer(samples, sr: sr), hits)
}
