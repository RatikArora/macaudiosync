import Foundation

/// Estimates the relative frequency error (drift) between the client clock
/// and the master clock, in parts-per-million, by fitting a line through
/// (clientTime, measuredOffset) points with least squares.
///
/// Two crystal oscillators never run at exactly the same rate; a typical
/// pair of Macs drifts a few ppm apart (≈ a few ms per hour). The
/// `ClockSynchronizer`'s sliding window already *tracks* that drift, so
/// playback stays aligned — this estimator exists to *measure and report* it
/// (and is the input you would feed a micro-resampler in a future version).
public final class DriftEstimator {
    private var points: [(x: Double, y: Double)] = []
    private let windowSize: Int
    private let lock = NSLock()

    public init(windowSize: Int = 300) {
        self.windowSize = windowSize
    }

    public func add(clientNs: UInt64, offsetNs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        points.append((Double(clientNs), Double(offsetNs)))
        if points.count > windowSize {
            points.removeFirst(points.count - windowSize)
        }
    }

    /// Drift in ppm (positive = master clock runs fast relative to client),
    /// or nil with fewer than 10 points.
    public var driftPpm: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard points.count >= 10 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var cov = 0.0, varX = 0.0
        for p in points {
            cov += (p.x - meanX) * (p.y - meanY)
            varX += (p.x - meanX) * (p.x - meanX)
        }
        guard varX > 0 else { return nil }
        return cov / varX * 1e6
    }
}
