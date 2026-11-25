import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

enum Kind: String { case kick, accent }
struct Hit { let time: Double; let kind: Kind; let strength: Double }
struct LoadedAudio {
    let file: AVAudioFile
    let mono: [Float]
    let sr: Double
    var duration: Double { Double(mono.count) / sr }
}
func load(_ url: URL) -> LoadedAudio {
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("File not found: \(url.path)", headline: "beatpad couldn't read the audio.")
    }
    do {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            fail("The file is empty or too large to load into memory.", headline: "beatpad couldn't read the audio.")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            fail("The file could not be decoded to PCM audio. Apple Music/DRM-protected files can't be read.")
        }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            for i in 0..<count {
                mono[i] += (buffer.format.isInterleaved ? channels[0][i * channelCount + c] : channels[c][i]) / Float(channelCount)
            }
        }
        return LoadedAudio(file: file, mono: mono, sr: buffer.format.sampleRate)
    } catch {
        fail("Unreadable or unsupported audio: \(url.lastPathComponent). Apple Music/DRM-protected files can't be read.\n\(error.localizedDescription)", headline: "beatpad couldn't read the audio.")
    }
}
