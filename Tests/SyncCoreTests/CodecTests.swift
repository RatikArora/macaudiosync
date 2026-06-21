import Testing
import Foundation
@testable import SyncCore

@Suite struct CodecTests {

    @Test func float32IsBitExact() throws {
        var rng = SeededRandom(seed: 1)
        let samples = (0..<512).map { _ in Float(rng.uniform(-1, 1)) }
        var w = BinaryWriter()
        AudioCodec.pcmFloat32.encodeSamples(samples, into: &w)
        var r = BinaryReader(w.data)
        let out = try AudioCodec.pcmFloat32.decodeSamples(&r, count: samples.count)
        #expect(out.map(\.bitPattern) == samples.map(\.bitPattern))
    }

    @Test func int16RoundTripWithinOneLSB() throws {
        var rng = SeededRandom(seed: 2)
        let samples = (0..<512).map { _ in Float(rng.uniform(-1, 1)) }
        var w = BinaryWriter()
        AudioCodec.pcmInt16.encodeSamples(samples, into: &w)
        var r = BinaryReader(w.data)
        let out = try AudioCodec.pcmInt16.decodeSamples(&r, count: samples.count)
        #expect(out.count == samples.count)
        for (a, b) in zip(out, samples) {
            #expect(abs(a - b) <= 1.0 / 32767.0 + 1e-6)
        }
    }

    @Test func int16ClampsOutOfRangeWithoutWrapping() throws {
        // The danger without clamping is 2.0 × 32767 overflowing Int16 and
        // wrapping to a large negative — a loud pop. Verify clamping holds.
        let samples: [Float] = [2.0, -2.0, 1.0, -1.0, 0.0]
        var w = BinaryWriter()
        AudioCodec.pcmInt16.encodeSamples(samples, into: &w)
        var r = BinaryReader(w.data)
        let out = try AudioCodec.pcmInt16.decodeSamples(&r, count: samples.count)
        #expect(out[0] > 0.9)   // +2.0 clamped toward +1, NOT wrapped negative
        #expect(out[1] < -0.9)  // -2.0 clamped toward -1
        #expect(out[4] == 0.0)
    }

    @Test func int16IsHalfTheBytesOfFloat32() {
        let samples = [Float](repeating: 0.5, count: 100)
        var wf = BinaryWriter(); AudioCodec.pcmFloat32.encodeSamples(samples, into: &wf)
        var wi = BinaryWriter(); AudioCodec.pcmInt16.encodeSamples(samples, into: &wi)
        #expect(wf.data.count == 400)
        #expect(wi.data.count == 200)
    }

    @Test func opusReservedButNotYetImplemented() {
        var r = BinaryReader(Data([0, 0, 0, 0]))
        #expect(throws: (any Error).self) { _ = try AudioCodec.opus.decodeSamples(&r, count: 1) }
    }

    @Test func int16BoundaryValuesAreExact() {
        // Symmetric ±32767 scale, clamped, never overflowing to -32768.
        #expect(AudioCodec.toInt16(1.0) == 32767)    // +full scale, no overflow
        #expect(AudioCodec.toInt16(-1.0) == -32767)  // symmetric, not -32768
        #expect(AudioCodec.toInt16(0) == 0)
        #expect(AudioCodec.toInt16(2.0) == 32767)    // clamped, not wrapped
        #expect(AudioCodec.toInt16(-2.0) == -32767)
        // A foreign encoder's asymmetric -32768 must clamp to -1.0, never below.
        #expect(AudioCodec.fromInt16(-32768) == -1.0)
        #expect(AudioCodec.fromInt16(Int16.max) == 1.0)
    }

    @Test func int16DecodeRejectsTruncatedPayload() {
        // Header claims 8 samples but only 2 bytes (1 sample) follow — must
        // throw rather than reserve/allocate from the attacker-chosen count.
        var r = BinaryReader(Data([0x00, 0x00]))
        #expect(throws: (any Error).self) { _ = try AudioCodec.pcmInt16.decodeSamples(&r, count: 8) }
    }
}
