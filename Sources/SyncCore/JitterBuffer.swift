import Foundation

/// Thread-safe buffer of `AudioChunk`s ordered by master-clock play time.
///
/// The network thread inserts chunks as datagrams arrive (possibly
/// out-of-order, duplicated, or late); the audio render thread asks for the
/// chunks overlapping its current output window and periodically drops
/// everything older than the playhead.
public final class JitterBuffer {
    private var chunks: [AudioChunk] = [] // sorted by playAtMasterNs
    private var lock = NSLock()
    /// Anything ending at/before this master time has already been played
    /// (or was dropped); late arrivals behind it are rejected.
    private var watermarkNs: UInt64 = 0

    // Diagnostics (all protected by `lock`).
    public private(set) var insertedCount = 0
    public private(set) var duplicateCount = 0
    public private(set) var lateCount = 0

    public init() {}

    /// Insert a chunk, keeping the buffer sorted. Duplicates (same sequence
    /// number currently buffered) and chunks entirely behind the playhead
    /// watermark are rejected.
    @discardableResult
    public func insert(_ chunk: AudioChunk) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if chunk.endMasterNs <= watermarkNs {
            lateCount += 1
            return false
        }
        // Binary search for insertion point by play time.
        var lo = 0, hi = chunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if chunks[mid].playAtMasterNs < chunk.playAtMasterNs { lo = mid + 1 } else { hi = mid }
        }
        // Duplicate check in the timestamp neighborhood (same sequence).
        for i in max(0, lo - 2)..<min(chunks.count, lo + 2) where chunks[i].sequence == chunk.sequence {
            duplicateCount += 1
            return false
        }
        chunks.insert(chunk, at: lo)
        insertedCount += 1
        return true
    }

    /// Snapshot of the chunks overlapping the half-open master-time window
    /// [startNs, endNs).
    public func chunksOverlapping(startNs: UInt64, endNs: UInt64) -> [AudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.filter { $0.endMasterNs > startNs && $0.playAtMasterNs < endNs }
    }

    /// Drop chunks that end at or before `ns` and advance the late-arrival
    /// watermark. Call this with the start of each render window.
    public func dropChunks(endingBefore ns: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        watermarkNs = max(watermarkNs, ns)
        chunks.removeAll { $0.endMasterNs <= ns }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }

    /// Total buffered audio duration in nanoseconds (gaps not subtracted).
    public var bufferedSpanNs: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard let first = chunks.first, let last = chunks.last else { return 0 }
        return last.endMasterNs - first.playAtMasterNs
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        chunks.removeAll()
    }
}
