import Foundation

/// Streaming linear-interpolation resampler for interleaved Float32 audio.
///
/// Used by the sender's process-tap capture: Core Audio taps deliver audio
/// at the output device's native rate (often 44.1 kHz), while the wire
/// format runs at 48 kHz. Linear interpolation is plenty for v1 (≈ -70 dB
/// images on music); swap for a windowed-sinc kernel if golden ears object.
///
/// Stateful: carries the fractional read position and the last input frame
/// across `process` calls so chunk boundaries are seamless.
public final class LinearResampler {
    public let sourceRate: Double
    public let targetRate: Double
    public let channels: Int

    /// Fractional read position, in source frames, relative to `history`
    /// (the previous input's final frame) at index 0 followed by the current
    /// input. Starts at 1.0 = the first frame of the first input.
    private var position = 1.0
    private var history: [Float]
    private let ratio: Double

    public init(sourceRate: Double, targetRate: Double, channels: Int) {
        precondition(sourceRate > 0 && targetRate > 0 && channels > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.channels = channels
        self.ratio = sourceRate / targetRate
        self.history = [Float](repeating: 0, count: channels)
    }

    public var isPassthrough: Bool { sourceRate == targetRate }

    /// Resample one interleaved chunk. Returns the output frames available
    /// so far (length varies ±1 frame between calls; totals converge to
    /// inputFrames * targetRate / sourceRate).
    public func process(_ input: [Float]) -> [Float] {
        if isPassthrough { return input }
        precondition(input.count % channels == 0)
        let inputFrames = input.count / channels
        guard inputFrames > 0 else { return [] }

        // Source stream as seen by this call: history frame at position 0,
        // then input frames at positions 1...inputFrames.
        var output = [Float]()
        output.reserveCapacity(Int(Double(inputFrames) / ratio) * channels + channels)

        func sourceSample(_ frame: Int, _ ch: Int) -> Float {
            frame == 0 ? history[ch] : input[(frame - 1) * channels + ch]
        }

        while position <= Double(inputFrames) {
            let base = Int(position)
            let frac = Float(position - Double(base))
            for ch in 0..<channels {
                let a = sourceSample(base, ch)
                let b = base < inputFrames ? sourceSample(base + 1, ch) : a
                output.append(a + (b - a) * frac)
            }
            position += ratio
        }

        // Slide the window: keep the last input frame as next call's history.
        for ch in 0..<channels {
            history[ch] = input[(inputFrames - 1) * channels + ch]
        }
        position -= Double(inputFrames)
        return output
    }
}
