import Foundation

/// Phase-continuous sine generator used as a test source (`--tone` mode) and
/// by the test suite. Producing audio in chunks must not introduce phase
/// discontinuities at chunk boundaries — that would be audible as clicks and
/// would also break the continuity checks in the end-to-end tests.
public final class ToneGenerator {
    public let frequency: Double
    public let sampleRate: Double
    public let amplitude: Double
    public let channels: Int
    private var phase: Double = 0

    public init(frequency: Double = 440, sampleRate: Double = 48_000, amplitude: Double = 0.2, channels: Int = 2) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.channels = channels
    }

    /// Generate the next `frameCount` frames of interleaved samples,
    /// continuing from the previous chunk's phase.
    public func nextChunk(frameCount: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount * channels)
        let increment = 2.0 * Double.pi * frequency / sampleRate
        for frame in 0..<frameCount {
            let value = Float(sin(phase) * amplitude)
            for ch in 0..<channels {
                samples[frame * channels + ch] = value
            }
            phase += increment
            if phase > 2.0 * Double.pi {
                phase -= 2.0 * Double.pi
            }
        }
        return samples
    }
}
