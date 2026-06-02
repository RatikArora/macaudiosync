import Foundation

/// A contiguous run of interleaved Float32 PCM samples stamped with the
/// master-clock time at which its first frame must hit the speaker.
public struct AudioChunk: Equatable {
    /// Monotonically increasing per-stream sequence number (for duplicate /
    /// loss diagnostics — ordering is done by timestamp, not sequence).
    public let sequence: UInt32
    /// Master-clock nanosecond timestamp of the first frame.
    public let playAtMasterNs: UInt64
    public let sampleRate: Double
    public let channels: Int
    /// Interleaved samples: frame0[ch0, ch1, ...], frame1[ch0, ch1, ...], ...
    public let samples: [Float]

    public init(sequence: UInt32, playAtMasterNs: UInt64, sampleRate: Double, channels: Int, samples: [Float]) {
        precondition(channels > 0, "channels must be positive")
        precondition(samples.count % channels == 0, "samples must be a whole number of frames")
        self.sequence = sequence
        self.playAtMasterNs = playAtMasterNs
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    public var frameCount: Int { samples.count / channels }

    public var durationNs: UInt64 {
        UInt64((Double(frameCount) / sampleRate * 1e9).rounded())
    }

    /// Master-clock time one frame past the last frame of this chunk.
    public var endMasterNs: UInt64 { playAtMasterNs + durationNs }
}
