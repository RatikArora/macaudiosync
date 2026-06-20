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
}
