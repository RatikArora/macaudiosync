import Foundation

/// How an audio packet's samples are serialized on the wire. The tag travels
/// in every audio packet (see `Wire`), so the sender can switch tiers
/// mid-stream at a packet boundary and the receiver just reads the tag.
///
/// - `pcmFloat32`: the original lossless layout (4 bytes/sample). Bit-exact;
///   used by the end-to-end tests and available for wired links where
///   bandwidth is free.
/// - `pcmInt16`: 16-bit PCM (2 bytes/sample) — half the bandwidth, and below
///   the audible noise floor for normal listening (perceptually transparent).
///   This is the default on the wire.
/// - `opus` (reserved): a future perceptual tier (adaptive VBR + packet-loss
///   concealment). The value is reserved so adding it later doesn't shift the
///   other tags; decoders that don't implement it reject the packet cleanly.
public enum AudioCodec: UInt8 {
    case pcmFloat32 = 0
    case pcmInt16 = 1
    case opus = 2 // reserved — not yet implemented

    /// Bytes per sample on the wire (0 = variable/unsupported here).
    public var bytesPerSample: Int {
        switch self {
        case .pcmFloat32: return 4
        case .pcmInt16: return 2
        case .opus: return 0
        }
    }

    /// Append the interleaved samples to a wire writer in this codec's layout.
    public func encodeSamples(_ samples: [Float], into writer: inout BinaryWriter) {
        switch self {
        case .pcmFloat32:
            writer.put(samples)
        case .pcmInt16:
            for sample in samples {
                writer.put(UInt16(bitPattern: AudioCodec.toInt16(sample)))
            }
        case .opus:
            // Reserved; senders never select this until implemented.
            writer.put(samples)
        }
    }

    /// Read `count` interleaved samples from a wire reader in this codec's
    /// layout. Throws for codecs not supported by this build.
    public func decodeSamples(_ reader: inout BinaryReader, count: Int) throws -> [Float] {
        switch self {
        case .pcmFloat32:
            return try reader.floats(count: count)
        case .pcmInt16:
            var out = [Float]()
            out.reserveCapacity(count)
            for _ in 0..<count {
                out.append(AudioCodec.fromInt16(Int16(bitPattern: try reader.u16())))
            }
            return out
        case .opus:
            throw WireError.badPayload("opus codec not supported by this build")
        }
    }

    /// Float (nominally -1...1) → 16-bit PCM, clamped. 32767 (not 32768) so
    /// +1.0 and -1.0 map symmetrically and never overflow Int16.
    @inline(__always) static func toInt16(_ f: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, f))
        return Int16((clamped * 32767.0).rounded())
    }

    /// 16-bit PCM → Float. Divides by the SAME 32767 the encoder multiplied
    /// by, so a round trip is bit-accurate to within half an LSB (a symmetric
    /// scale; /32768 would add a ~1.5 LSB systematic error). Clamped in case a
    /// foreign encoder ever sends the asymmetric −32768.
    @inline(__always) static func fromInt16(_ i: Int16) -> Float {
        max(-1.0, min(1.0, Float(i) / 32767.0))
    }
}
