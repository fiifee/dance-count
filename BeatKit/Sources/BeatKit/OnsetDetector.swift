import Accelerate
import Foundation

/// One analysis frame of the onset front end (one hop, ~10 ms).
public struct OnsetFrame {
    /// Positive spectral flux over all bands, log-compressed. Peaks on note/drum attacks.
    public var flux: Float
    /// The same flux restricted to < ~200 Hz (kick drum, bass).
    public var lowFlux: Float
    /// Pitch-class magnitudes (C … B), used to spot chord changes.
    public var chroma: [Float]
}

/// Turns raw mono samples into onset-strength frames at ~100 frames per second.
/// Works at any sample rate (16 kHz Bluetooth mics up to 48 kHz built-in mics).
public final class OnsetDetector {
    public let sampleRate: Double
    public let hop: Int
    public let fftSize: Int
    public var frameRate: Double { sampleRate / Double(hop) }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var frame: [Float]
    private var pending: [Float] = []
    private let bandOfBin: [Int]
    private let bandCount: Int
    private let lowBandCount: Int
    private let pitchClassOfBin: [Int]
    private var previousBands: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int((sampleRate / 100).rounded()))
        // ~46 ms window: 2048 at 44.1/48 kHz, 1024 at 16/24 kHz.
        var n = 256
        while Double(n) < sampleRate * 0.04 { n *= 2 }
        fftSize = n
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        window = w
        frame = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)

        // Log-spaced bands from 30 Hz up to 10 kHz (or Nyquist).
        let binHz = sampleRate / Double(n)
        let top = min(10_000, sampleRate * 0.45)
        let edges = (0...36).map { 30 * pow(top / 30, Double($0) / 36) }
        var bandOfBin = [Int](repeating: -1, count: n / 2)
        for bin in 1..<(n / 2) {
            let f = Double(bin) * binHz
            if let b = edges.indices.dropLast().first(where: { f >= edges[$0] && f < edges[$0 + 1] }) {
                bandOfBin[bin] = b
            }
        }
        self.bandOfBin = bandOfBin
        bandCount = 36
        lowBandCount = edges.firstIndex(where: { $0 >= 200 }) ?? 1
        previousBands = [Float](repeating: 0, count: 36)

        var pcOfBin = [Int](repeating: -1, count: n / 2)
        for bin in 1..<(n / 2) {
            let f = Double(bin) * binHz
            guard f >= 60, f <= 2100 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            pcOfBin[bin] = ((Int(midi.rounded()) % 12) + 12) % 12
        }
        pitchClassOfBin = pcOfBin
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Feed samples; `emit` is called once per completed hop.
    public func process(_ samples: UnsafeBufferPointer<Float>, emit: (OnsetFrame) -> Void) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= hop {
            frame.removeFirst(hop)
            frame.append(contentsOf: pending[offset..<(offset + hop)])
            offset += hop
            emit(analyze())
        }
        pending.removeFirst(offset)
    }

    private func analyze() -> OnsetFrame {
        let half = fftSize / 2
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        var scale = 2 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        var bands = [Float](repeating: 0, count: bandCount)
        var chroma = [Float](repeating: 0, count: 12)
        for bin in 1..<half {
            let m = magnitudes[bin]
            let b = bandOfBin[bin]
            if b >= 0 { bands[b] += m }
            let pc = pitchClassOfBin[bin]
            if pc >= 0 { chroma[pc] += m }
        }
        var flux: Float = 0
        var lowFlux: Float = 0
        for b in 0..<bandCount {
            let v = log1pf(1000 * bands[b])
            let d = v - previousBands[b]
            if d > 0 {
                flux += d
                if b < lowBandCount { lowFlux += d }
            }
            previousBands[b] = v
        }
        return OnsetFrame(flux: flux, lowFlux: lowFlux, chroma: chroma)
    }
}
