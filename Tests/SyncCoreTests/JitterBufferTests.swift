import Testing
import Foundation
@testable import SyncCore

@Suite struct JitterBufferTests {

    private func chunk(seq: UInt32, playAtMs: UInt64, frames: Int = 160, value: Float = 0.5) -> AudioChunk {
        AudioChunk(
            sequence: seq,
            playAtMasterNs: playAtMs * 1_000_000,
            sampleRate: 48_000,
            channels: 2,
            samples: [Float](repeating: value, count: frames * 2)
        )
    }

    @Test func outOfOrderInsertionIsSortedByTimestamp() {
        let buffer = JitterBuffer()
        // Arrive wildly out of order, as UDP allows.
        for (seq, ms) in [(3, 30), (1, 10), (5, 50), (2, 20), (4, 40)] {
            #expect(buffer.insert(chunk(seq: UInt32(seq), playAtMs: UInt64(ms))))
        }
        let all = buffer.chunksOverlapping(startNs: 0, endNs: .max)
        #expect(all.map(\.sequence) == [1, 2, 3, 4, 5])
    }

    @Test func duplicatesRejected() {
        let buffer = JitterBuffer()
        #expect(buffer.insert(chunk(seq: 1, playAtMs: 10)))
        #expect(!buffer.insert(chunk(seq: 1, playAtMs: 10)), "identical retransmit must be rejected")
        #expect(buffer.count == 1)
        #expect(buffer.duplicateCount == 1)
    }

    @Test func lateChunkRejectedAfterPlayheadPassed() {
        let buffer = JitterBuffer()
        buffer.insert(chunk(seq: 1, playAtMs: 10))
        buffer.insert(chunk(seq: 2, playAtMs: 20))
        // Playhead advances past 25ms.
        buffer.dropChunks(endingBefore: 25_000_000)
        #expect(buffer.count == 0)
        // A straggler for t=15ms arrives — it's already in the past.
        #expect(!buffer.insert(chunk(seq: 3, playAtMs: 15)))
        #expect(buffer.lateCount == 1)
        // But audio for the future is welcome.
        #expect(buffer.insert(chunk(seq: 4, playAtMs: 30)))
    }

    @Test func overlapQueryIsHalfOpenAndExact() {
        let buffer = JitterBuffer()
        // 160 frames @48k = 3.333ms per chunk; place three back-to-back from 10ms.
        let frames = 160
        let durNs = UInt64(Double(frames) / 48_000 * 1e9)
        let base: UInt64 = 10_000_000
        for i in 0..<3 {
            buffer.insert(AudioChunk(
                sequence: UInt32(i + 1),
                playAtMasterNs: base + UInt64(i) * durNs,
                sampleRate: 48_000, channels: 2,
                samples: [Float](repeating: 0.1, count: frames * 2)
            ))
        }
        // Window exactly covering the middle chunk.
        let mid = buffer.chunksOverlapping(startNs: base + durNs, endNs: base + 2 * durNs)
        #expect(mid.map(\.sequence) == [2])
        // Window touching only the boundary instant must match nothing
        // (half-open semantics).
        let boundary = buffer.chunksOverlapping(startNs: base + durNs, endNs: base + durNs)
        #expect(boundary.isEmpty)
        // Window straddling chunks 1 and 2.
        let straddle = buffer.chunksOverlapping(startNs: base + durNs / 2, endNs: base + durNs + durNs / 2)
        #expect(straddle.map(\.sequence) == [1, 2])
    }

    @Test func dropKeepsFutureAudio() {
        let buffer = JitterBuffer()
        for i in 1...10 {
            buffer.insert(chunk(seq: UInt32(i), playAtMs: UInt64(i * 10))) // 10..100 ms
        }
        // Each chunk is 160 frames = 3.33 ms long, so chunk 5 (50–53.3 ms)
        // ends before the 55 ms playhead and must go too.
        buffer.dropChunks(endingBefore: 55_000_000)
        let remaining = buffer.chunksOverlapping(startNs: 0, endNs: .max)
        #expect(remaining.map(\.sequence) == [6, 7, 8, 9, 10].map(UInt32.init))
    }

    @Test func concurrentInsertAndRenderDoesNotCrashOrLoseData() {
        // Network thread inserting while "render thread" queries and drops —
        // exercises the locking under real contention.
        let buffer = JitterBuffer()
        let total = 2_000
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            for i in 0..<total {
                buffer.insert(self.chunk(seq: UInt32(i + 1), playAtMs: UInt64(1_000 + i * 5)))
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<500 {
                _ = buffer.chunksOverlapping(startNs: 0, endNs: 2_000_000_000)
                _ = buffer.bufferedSpanNs
            }
            group.leave()
        }
        let result = group.wait(timeout: .now() + 30)
        #expect(result == .success, "concurrent operations deadlocked")
        #expect(buffer.insertedCount == total)
        #expect(buffer.count == total)
        // Everything must still be perfectly sorted after concurrent access.
        let all = buffer.chunksOverlapping(startNs: 0, endNs: .max)
        #expect(all.map(\.playAtMasterNs) == all.map(\.playAtMasterNs).sorted())
    }
}
