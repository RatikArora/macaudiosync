import Foundation
import Accelerate

/// Real-time frequency spectrum of the audio being played, for the receiver's
/// visualizer. The audio thread feeds it samples cheaply; a slower timer thread
/// pulls a normalized set of log-spaced band magnitudes (an actual FFT of the
/// signal — not a synthetic animation).
///
/// Bands are log-spaced (perceptual), magnitudes are auto-gained so the display
/// stays lively across quiet and loud passages — exactly how a music visualizer
/// behaves — while a noise floor keeps true silence flat.
public final class SpectrumAnalyzer {
    public let bandCount: Int
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let sampleRate: Double

    private let lock = NSLock()
    private var ring: [Float]
    private var writeIdx = 0

    private let bandBins: [(lo: Int, hi: Int)]
    private var agc: Float = 1e-4

    public init(bandCount: Int = 32, sampleRate: Double = 48_000) {
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        self.log2n = vDSP_Length(round(log2(Double(fftSize))))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = w
        self.ring = [Float](repeating: 0, count: fftSize)

        // Log-spaced band edges from ~40 Hz to ~16 kHz.
        let nyqBins = fftSize / 2
        let minF = 40.0
        let maxF = min(16_000.0, sampleRate / 2)
        var edges: [(Int, Int)] = []
        for b in 0..<bandCount {
            let f0 = minF * pow(maxF / minF, Double(b) / Double(bandCount))
            let f1 = minF * pow(maxF / minF, Double(b + 1) / Double(bandCount))
            let lo = max(1, Int(f0 * Double(fftSize) / sampleRate))
            let hi = max(lo + 1, min(nyqBins, Int(f1 * Double(fftSize) / sampleRate)))
            edges.append((lo, hi))
        }
        self.bandBins = edges
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Append interleaved output samples (mono-mixed into the ring). Cheap;
    /// safe to call from the audio render thread.
    public func append(_ samples: UnsafeBufferPointer<Float>, frames: Int, channels: Int) {
        guard channels > 0, frames > 0 else { return }
        lock.lock()
        var w = writeIdx
        for f in 0..<frames {
            var m: Float = 0
            for ch in 0..<channels { m += samples[f * channels + ch] }
            ring[w] = m / Float(channels)
            w += 1
            if w == fftSize { w = 0 }
        }
        writeIdx = w
        lock.unlock()
    }

    /// Compute the current normalized band magnitudes (0...1). Call from a
    /// timer thread (~20–30 Hz); do not call from the audio thread.
    public func bands() -> [Float] {
        // Snapshot the ring in chronological order.
        var input = [Float](repeating: 0, count: fftSize)
        lock.lock()
        let w = writeIdx
        for i in 0..<fftSize {
            var j = w + i
            if j >= fftSize { j -= fftSize }
            input[i] = ring[j]
        }
        lock.unlock()

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var mags = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        var out = [Float](repeating: 0, count: bandCount)
        var frameMax: Float = 0
        for (i, band) in bandBins.enumerated() {
            var sum: Float = 0
            for k in band.lo..<band.hi { sum += mags[k] }
            let v = sum / Float(max(1, band.hi - band.lo))
            out[i] = v
            if v > frameMax { frameMax = v }
        }

        // Below the noise floor: report flat silence, don't amplify hiss.
        if frameMax < 1e-3 { return [Float](repeating: 0, count: bandCount) }

        // Auto-gain: normalize to a slowly-decaying running peak so the display
        // tracks relative dynamics instead of absolute level.
        agc = max(frameMax, agc * 0.97)
        let inv = 1.0 / max(agc, 1e-6)
        for i in 0..<bandCount {
            let n = min(1, max(0, out[i] * inv))
            out[i] = powf(n, 0.6) // gamma: lift quiet detail for visual pop
        }
        return out
    }
}
