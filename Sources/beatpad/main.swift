import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Command line

struct Options {
    var file: String?
    var help = false
    var selftest = false
    var simulateFile: String?
    var jitterUS = 200.0
    var spliceAt: Double?
    var metronome = false
    var listen = false
    var melody = false
    var melodyOnly = false
    var melodyLevel = 0.5
    var melodyOctave = 0
    var live = false
    var app: String?
    var input: String?
    var listApps = false
    var allApps = false
    var inputList = false
    var systemAudio = false
    var seconds: Double?
    var dryRun = false
    var offsetMs = 0.0
    var level = 1.0
    var dynamics = true
    var dynamicsRange = 15.0
    var followVolume = true
    var sensitivity = 0.5
    var kickOnly = false
    var start = 0.0
    var bpm: Double?
    var mode = AnalysisMode.beat
    var anyOutput = false
    var external = false
    var writeTestTrack: String?
}
let help = """
beatpad — feel the beat and melody through a Force Touch trackpad

Usage:
  beatpad <audio-file> [options]   play audio with haptic beats
  beatpad --metronome [--bpm N]   16 beats of clicks + thumps
  beatpad --listen [--app NAME_OR_BUNDLE_ID | --input [DEVICE] | --system] [--seconds N]
                                 meter live app audio (macOS 14.2+); no haptics
  beatpad --live [--app NAME_OR_BUNDLE_ID | --input [DEVICE] | --system] [--seconds N] [options]
                                 predict live beats with haptics (macOS 14.2+)
  beatpad --list-apps             list audio apps and output activity (macOS 14.2+)
  beatpad --input-list            list input devices
  beatpad --help

Options:
  --app NAME_OR_BUNDLE_ID  capture a running app and its helper processes
  --input [DEVICE]   capture default input, a device name substring, or exact UID
  --list-apps        list playing apps; --all includes every audio process
  --input-list       list input device names, UIDs, and channel counts
  --melody           add live melody tones (also available with --simulate-live)
  --melody-only      melody without beat thumps (implies --melody)
  --melody-level X   melody strength relative to --level, 0…1 (default 0.5)
  --melody-octave N  shift melody by -2…+2 octaves (default 0)
  --system           capture all system audio (default for --listen/--live)
  --seconds N        stop --listen/--live after N seconds (>0); otherwise Ctrl-C
  --dry-run          print hit time, kind, strength and totals; no audio or motor
  --offset-ms N      shift haptics vs audio, + = later (default 0)
  --level X          master haptic strength 0…1 (default 1.0)
  --no-dynamics      disable song dynamics (enabled by default; excludes metronome)
  --dynamics-range DB  quiet-to-loud range in dB (>0; default 15)
  --no-follow-volume  disable following the Mac output volume (enabled by default)
  --sensitivity X    0…1, higher = more hits (default 0.5)
  --mode beat|onsets beat: tracked beats (default); onsets: individual onset detector
  --kick-only        thumps only: drop beat ticks or onset accents
  --start SEC        start SEC seconds into the file (default 0)
  --bpm N            force file/live beat tempo, or metronome tempo (default 120); >0
  --any-output       allow built-in trackpad with any audio output (lid must be open)
  --external         use an external Magic Trackpad

Development:
  --selftest            check analysis and scheduling; no audio or motor
  --write-test-track PATH  write a synthetic 12-second WAV
  --simulate-live FILE  measure live tracking against the full offline grid
  --splice-at SEC       separate segment references and measure splice recovery
  --jitter-us N         chunk timestamp jitter ±N µs (default 200; simulation only)

Rest your fingertips lightly on the trackpad; keep speaker volume moderate.
Apple Music/DRM-protected files can't be read. Ctrl-C stops playback.
Use --metronome to tune --offset-ms.
"""
func parseOptions() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    var result = Options(), seen = Set<String>(), i = 0, positional = false
    while i < args.count {
        let arg = args[i]
        if !positional && arg == "--" { positional = true; i += 1; continue }
        if !positional && arg.hasPrefix("-") {
            guard seen.insert(arg).inserted else { usageError("Repeated option: \(arg)") }
            func value() -> String {
                guard i + 1 < args.count else { usageError("\(arg) needs a value") }
                i += 1
                return args[i]
            }
            func number() -> Double {
                let text = value()
                guard let n = Double(text), n.isFinite else { usageError("\(arg) needs a finite number") }
                return n
            }
            switch arg {
            case "--help", "-h": result.help = true
            case "--selftest": result.selftest = true
            case "--simulate-live":
                result.simulateFile = value()
                if result.simulateFile!.isEmpty || result.simulateFile!.hasPrefix("--") { usageError("--simulate-live needs a file path") }
            case "--jitter-us":
                result.jitterUS = number()
                if result.jitterUS < 0 { usageError("--jitter-us must be at least 0") }
            case "--splice-at":
                result.spliceAt = number()
                if result.spliceAt! <= 0 { usageError("--splice-at must be greater than 0") }
            case "--metronome": result.metronome = true
            case "--listen": result.listen = true
            case "--live": result.live = true
            case "--melody": result.melody = true
            case "--melody-only": result.melodyOnly = true; result.melody = true
            case "--melody-level":
                result.melodyLevel = number()
                if !(0...1).contains(result.melodyLevel) { usageError("--melody-level must be between 0 and 1") }
            case "--melody-octave":
                let n = number()
                if !(-2...2).contains(n) || n.rounded() != n { usageError("--melody-octave must be an integer from -2 to 2") }
                result.melodyOctave = Int(n)
            case "--app":
                result.app = value()
                if result.app!.isEmpty || result.app!.hasPrefix("--") { usageError("--app needs a name or bundle ID") }
            case "--list-apps": result.listApps = true
            case "--all": result.allApps = true
            case "--input-list": result.inputList = true
            case "--input":
                result.input = ""
                if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    result.input = value()
                }
            case "--system": result.systemAudio = true
            case "--seconds":
                result.seconds = number()
                if result.seconds! <= 0 { usageError("--seconds must be greater than 0") }
            case "--dry-run": result.dryRun = true
            case "--kick-only": result.kickOnly = true
            case "--any-output": result.anyOutput = true
            case "--external": result.external = true
            case "--offset-ms": result.offsetMs = number()
            case "--level":
                result.level = number()
                if !(0...1).contains(result.level) { usageError("--level must be between 0 and 1") }
            case "--no-dynamics": result.dynamics = false
            case "--no-follow-volume": result.followVolume = false
            case "--dynamics-range":
                result.dynamicsRange = number()
                if result.dynamicsRange <= 0 { usageError("--dynamics-range must be greater than 0") }
            case "--sensitivity":
                result.sensitivity = number()
                if !(0...1).contains(result.sensitivity) { usageError("--sensitivity must be between 0 and 1") }
            case "--start":
                result.start = number()
                if result.start < 0 { usageError("--start must be at least 0") }
            case "--mode":
                guard let mode = AnalysisMode(rawValue: value()) else { usageError("--mode must be beat or onsets") }
                result.mode = mode
            case "--bpm":
                let bpm = number()
                if bpm <= 0 { usageError("--bpm must be greater than 0") }
                result.bpm = bpm
            case "--write-test-track":
                result.writeTestTrack = value()
                if result.writeTestTrack!.isEmpty || result.writeTestTrack!.hasPrefix("--") { usageError("--write-test-track needs a path") }
            default: usageError("Unknown option: \(arg)")
            }
        } else {
            guard result.file == nil else { usageError("Expected only one audio file") }
            result.file = arg
        }
        i += 1
    }
    if !result.live && result.simulateFile == nil && !seen.isDisjoint(with: ["--melody", "--melody-only", "--melody-level", "--melody-octave"]) {
        usageError("Melody options require --live or --simulate-live")
    }
    if seen.contains("--jitter-us") && result.simulateFile == nil { usageError("--jitter-us requires --simulate-live") }
    if result.spliceAt != nil && result.simulateFile == nil { usageError("--splice-at requires --simulate-live") }
    if result.anyOutput && !result.live && result.file == nil && !result.metronome && !result.help {
        usageError("--any-output requires --live, an audio file, or --metronome")
    }
    if result.allApps && !result.listApps { usageError("--all requires --list-apps") }
    let modes = [result.simulateFile != nil, result.file != nil, result.metronome, result.listen, result.live, result.selftest, result.writeTestTrack != nil, result.listApps, result.inputList].filter { $0 }.count
    if modes > 1 { usageError("Choose one audio file, --metronome, --listen, --live, --selftest, --simulate-live, --write-test-track, --list-apps, or --input-list") }
    if result.simulateFile != nil && !seen.isDisjoint(with: ["--dry-run", "--offset-ms", "--level", "--sensitivity", "--mode", "--kick-only", "--start", "--bpm", "--external"]) {
        usageError("--simulate-live accepts melody options, --jitter-us, --splice-at, --no-dynamics, --dynamics-range and --no-follow-volume")
    }
    if !result.listen && !result.live && !seen.isDisjoint(with: ["--app", "--system", "--input", "--seconds"]) {
        usageError("--app, --system, --input, and --seconds require --listen or --live")
    }
    if [seen.contains("--app"), result.systemAudio, result.input != nil].filter({ $0 }).count > 1 { usageError("Choose one source: --app, --system, or --input") }
    if result.listen && !seen.isDisjoint(with: ["--dry-run", "--offset-ms", "--level", "--sensitivity", "--mode", "--kick-only", "--start", "--bpm", "--external"]) {
        usageError("Playback and analysis options cannot be used with --listen")
    }
    if result.live && !seen.isDisjoint(with: ["--dry-run", "--mode", "--start"]) {
        usageError("--dry-run, --mode, and --start cannot be used with --live")
    }
    if !result.help && modes == 0 { usageError("Supply an audio file or a mode") }
    if (result.selftest || result.writeTestTrack != nil) && result.dryRun { usageError("--dry-run needs an audio file or --metronome") }
    return result
}

let options = parseOptions()
if options.help { print(help); exit(0) }
if options.selftest { exit(selftest()) }
if options.listApps || options.inputList {
    do {
        if options.inputList { try listInputs() }
        else if #available(macOS 14.2, *) { try listAudioApps(all: options.allApps) }
        else { fail("--list-apps requires macOS 14.2 or later.") }
        exit(0)
    } catch { fail(String(describing: error), headline: "beatpad couldn't list audio sources.") }
}
if let path = options.simulateFile { simulateLive(load(URL(fileURLWithPath: path)), jitterUS: options.jitterUS, spliceAt: options.spliceAt, dynamicsEnabled: options.dynamics, dynamicsRange: options.dynamicsRange, melodyEnabled: options.melody); exit(0) }
if options.listen || options.live {
    if #available(macOS 14.2, *) { listen(options: options); exit(0) }
    else { fail("--listen and --live require macOS 14.2 or later.", headline: "beatpad couldn't capture audio.") }
}
if let path = options.writeTestTrack {
    writeWAV(testTrack().samples, sr: 44100, url: URL(fileURLWithPath: path))
    print("Wrote 12.000 s selftest track: \(path)")
    exit(0)
}
preferExternal = options.external
if options.metronome {
    let track = metronome(bpm: options.bpm ?? 120)
    let duration = Double(track.buffer.frameLength) / track.buffer.format.sampleRate
    if options.start >= duration { usageError("--start must be less than the audio duration") }
    if options.dryRun { printHits(track.hits, startSec: options.start) }
    else {
        print("if the thump comes before the click, raise --offset-ms")
        playback(file: nil, buffer: track.buffer, duration: duration, name: "Metronome (\(options.bpm ?? 120) bpm)", hits: track.hits, options: options)
    }
} else if let path = options.file {
    let url = URL(fileURLWithPath: path), audio = load(url)
    if options.start >= audio.duration { usageError("--start must be less than the audio duration") }
    let result = analyze(audio.mono, sr: audio.sr, sensitivity: options.sensitivity, mode: options.mode, bpm: options.bpm)
    let hits = result.hits.filter { !options.kickOnly || $0.kind == .kick }
    if options.dryRun {
        if let bpm = result.bpm { print(String(format: "Tempo: %.1f bpm", bpm)) }
        printHits(hits, startSec: options.start)
    } else { playback(file: audio.file, buffer: nil, duration: audio.duration, name: url.lastPathComponent, hits: hits, options: options, bpm: result.bpm, dynamicsGains: options.dynamics ? fileDynamics(audio.mono, rate: audio.sr, hits: hits, range: options.dynamicsRange) : nil) }
}
