import Testing
import Foundation
@testable import SyncCore

@Suite struct WireTests {

    // MARK: - Round trips

    @Test func helloRoundTrip() throws {
        #expect(try Wire.decode(Wire.encode(.hello)) == .hello)
    }

    @Test func clockRequestRoundTrip() throws {
        let message = Message.clockRequest(clientSendNs: 0xDEAD_BEEF_CAFE_F00D)
        #expect(try Wire.decode(Wire.encode(message)) == message)
    }

    @Test func clockReplyRoundTrip() throws {
        let message = Message.clockReply(
            clientSendNs: 1,
            serverRecvNs: UInt64.max,
            serverSendNs: 0
        )
        #expect(try Wire.decode(Wire.encode(message)) == message)
    }

    @Test func audioRoundTripPreservesEverySampleBitExactly() throws {
        var rng = SeededRandom(seed: 42)
        let samples = (0..<320).map { _ in Float(rng.uniform(-1, 1)) }
        let chunk = AudioChunk(
            sequence: 123_456,
            playAtMasterNs: 9_876_543_210_123,
            sampleRate: 48_000,
            channels: 2,
            samples: samples
        )
        let decoded = try Wire.decode(Wire.encode(.audio(chunk)))
        guard case .audio(let result) = decoded else {
            Issue.record("expected audio message, got \(decoded)")
            return
        }
        #expect(result.sequence == chunk.sequence)
        #expect(result.playAtMasterNs == chunk.playAtMasterNs)
        #expect(result.sampleRate == chunk.sampleRate)
        #expect(result.channels == chunk.channels)
        // Bit-exact: float encoding must not lose precision.
        #expect(result.samples.map(\.bitPattern) == chunk.samples.map(\.bitPattern))
    }

    @Test func audioRoundTripWithSpecialFloatValues() throws {
        let samples: [Float] = [0, -0.0, 1, -1, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        let chunk = AudioChunk(sequence: 1, playAtMasterNs: 0, sampleRate: 48_000, channels: 1, samples: samples)
        guard case .audio(let result) = try Wire.decode(Wire.encode(.audio(chunk))) else {
            Issue.record("expected audio")
            return
        }
        #expect(result.samples.map(\.bitPattern) == samples.map(\.bitPattern))
    }

    // MARK: - Malformed input must be rejected, never crash

    @Test func emptyDataThrowsTruncated() {
        #expect(throws: WireError.truncated) { try Wire.decode(Data()) }
    }

    @Test func badMagicThrows() {
        var data = Wire.encode(.hello)
        data[0] = 0xFF
        #expect(throws: WireError.badMagic) { try Wire.decode(data) }
    }

    @Test func unsupportedVersionThrows() {
        var data = Wire.encode(.hello)
        data[4] = 99
        #expect(throws: WireError.unsupportedVersion(99)) { try Wire.decode(data) }
    }

    @Test func unknownTypeThrows() {
        var data = Wire.encode(.hello)
        data[5] = 200
        #expect(throws: WireError.unknownType(200)) { try Wire.decode(data) }
    }

    @Test func truncatedAudioPayloadThrows() throws {
        let chunk = AudioChunk(
            sequence: 7, playAtMasterNs: 1_000, sampleRate: 48_000, channels: 2,
            samples: [Float](repeating: 0.5, count: 64)
        )
        let full = Wire.encode(.audio(chunk))
        // Chop the datagram at every possible length; none may crash, all
        // must throw (except the full length, which must decode).
        for length in 0..<full.count {
            #expect(throws: (any Error).self, "length \(length) should throw") {
                try Wire.decode(full.prefix(length))
            }
        }
        #expect(throws: Never.self) { try Wire.decode(full) }
    }

    @Test func absurdFrameCountRejected() {
        // Hand-craft an audio header claiming 2^20 frames with no payload.
        var w = BinaryWriter()
        w.putBytes(Wire.magic)
        w.put(Wire.version)
        w.put(PacketType.audio.rawValue)
        w.put(UInt32(1))            // sequence
        w.put(UInt64(0))            // playAt
        w.put(UInt32(48_000))       // sample rate
        w.put(UInt16(2))            // channels
        w.put(UInt32(1 << 20))      // frameCount — absurd
        #expect(throws: (any Error).self) { try Wire.decode(w.data) }
    }

    @Test func zeroSampleRateRejected() {
        var w = BinaryWriter()
        w.putBytes(Wire.magic)
        w.put(Wire.version)
        w.put(PacketType.audio.rawValue)
        w.put(UInt32(1))
        w.put(UInt64(0))
        w.put(UInt32(0))            // zero sample rate
        w.put(UInt16(2))
        w.put(UInt32(0))
        #expect(throws: (any Error).self) { try Wire.decode(w.data) }
    }

    @Test func randomGarbageNeverCrashes() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<500 {
            let length = rng.int(0, 200)
            let garbage = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            _ = try? Wire.decode(garbage) // must not crash
        }
    }

    @Test func audioPacketStaysUnderMTU() {
        // The fan-out splits at maxFramesPerPacket; verify the resulting
        // datagram actually fits a standard 1500-byte MTU.
        let chunk = AudioChunk(
            sequence: 1, playAtMasterNs: 0, sampleRate: 48_000, channels: 2,
            samples: [Float](repeating: 0, count: Wire.maxFramesPerPacket * 2)
        )
        let data = Wire.encode(.audio(chunk))
        #expect(data.count <= 1472, "audio datagram must fit in MTU minus IP+UDP headers")
    }
}
