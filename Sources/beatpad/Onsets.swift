import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Double(sorted.count - 1) * p
    let lo = Int(index), hi = min(sorted.count - 1, Int(index) + 1)
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (index - Double(lo))
}
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func peaks(_ odf: [Double], kind: Kind, sr: Double, sensitivity: Double) -> [Hit] {
    guard odf.count > 1 else { return [] }
    let fps = sr / Double(hopSize), w = max(1, Int((0.1 * fps).rounded()))
    let delta = percentile(odf, 0.90) * lerp(1.2, 0.2, sensitivity)
    let p99 = max(1e-12, percentile(odf, 0.99))
    var sums = [Double](repeating: 0, count: odf.count + 1)
    for n in odf.indices { sums[n + 1] = sums[n] + odf[n] }
    var candidates: [Int] = []
    for n in 1..<odf.count {
        let lo = max(0, n - w), hi = min(odf.count - 1, n + w)
        let mean = (sums[hi + 1] - sums[lo]) / Double(hi - lo + 1)
        if odf[n] > 0, odf[n] >= mean + delta,
           odf[n] == odf[max(0, n - 3)...min(odf.count - 1, n + 3)].max()! {
            candidates.append(n)
        }
    }
    // Strongest-first suppression keeps the stronger peak, including chains of nearby peaks.
    let spacing = kind == .kick ? 0.100 : 0.120
    var selected: [Int] = []
    for n in candidates.sorted(by: { odf[$0] == odf[$1] ? $0 < $1 : odf[$0] > odf[$1] }) {
        if !selected.contains(where: { Double(abs($0 - n)) / fps < spacing }) { selected.append(n) }
    }
    return selected.sorted().map { n in
        Hit(time: Double(n * hopSize + fftSize / 2) / sr - onsetBias,
            kind: kind, strength: min(1, max(0, odf[n] / p99)))
    }
}
final class OnsetWorkspace {
    let fft: FFTSetup
    let half = fftSize / 2
    var window = [Float](repeating: 0, count: fftSize)
    var input = [Float](repeating: 0, count: fftSize)
    var real = [Float](repeating: 0, count: fftSize / 2)
    var imag = [Float](repeating: 0, count: fftSize / 2)
    var previous = [Double](repeating: 0, count: fftSize / 2)
    var hasPrevious = false
    let kickBins: [Int], accentBins: [Int]
    init(sr: Double) throws {
        guard let setup = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2)) else { throw CaptureError(description: "Couldn't create the FFT.") }
        fft = setup
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        kickBins = (0..<fftSize / 2).filter { (40.0...160.0).contains(Double($0) * sr / Double(fftSize)) }
        accentBins = (0..<fftSize / 2).filter { (150.0...6000.0).contains(Double($0) * sr / Double(fftSize)) }
    }
    deinit { vDSP_destroy_fftsetup(fft) }
    func onsetFrame(_ sample: (Int) -> Float) -> (Double, Double) {
        for i in 0..<fftSize { input[i] = sample(i) * window[i] }
        var kick = 0.0, accent = 0.0
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(11), FFTDirection(FFT_FORWARD))
            }
        }
        // zrip packs Nyquist into imag[0]; it is outside both onset bands.
        imag[0] = 0
        var compressed = [Double](repeating: 0, count: half)
        for k in 0..<half {
            let mag = hypot(Double(real[k]), Double(imag[k])) / Double(2 * fftSize)
            compressed[k] = log1p(100 * mag)
        }
        if hasPrevious {
            for k in kickBins { kick += max(0, compressed[k] - previous[k]) }
            for k in accentBins { accent += max(0, compressed[k] - previous[k]) }
        }
        previous = compressed; hasPrevious = true
        return (kick, accent)
    }
    func reset() { hasPrevious = false }
}
func onsetFunctions(_ mono: [Float], sr: Double) -> (kicks: [Double], accents: [Double]) {
    guard !mono.isEmpty else { return ([], []) }
    let workspace: OnsetWorkspace
    do { workspace = try OnsetWorkspace(sr: sr) }
    catch { fail(String(describing: error)) }
    let frames = max(1, (max(0, mono.count - fftSize) + hopSize - 1) / hopSize + 1)
    var kicks = [Double](), accents = [Double]()
    for n in 0..<frames {
        let start = n * hopSize
        let (kick, accent) = workspace.onsetFrame { start + $0 < mono.count ? mono[start + $0] : 0 }
        kicks.append(kick); accents.append(accent)
    }
    return (kicks, accents)
}

