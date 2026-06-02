import Foundation

/// Nanosecond-resolution monotonic clock shared by every component.
///
/// `CLOCK_UPTIME_RAW` is the nanosecond equivalent of `mach_absolute_time()`,
/// which is the same time base AVAudioEngine / Core Audio host timestamps use.
/// That lets us convert audio render deadlines to/from our wire timestamps
/// without any extra clock domain hops.
public enum MonotonicClock {
    /// Nanoseconds since boot (does not advance while the machine sleeps).
    public static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Convert mach host ticks (e.g. `AudioTimeStamp.mHostTime`) to nanoseconds.
    public static func ns(fromHostTicks ticks: UInt64) -> UInt64 {
        // Double has a 53-bit mantissa; uptime ns values stay well below 2^53
        // for years of uptime, so this conversion is exact enough (<1 ns error).
        UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
    }

    /// Convert nanoseconds to mach host ticks (for scheduling audio).
    public static func hostTicks(fromNs ns: UInt64) -> UInt64 {
        UInt64(Double(ns) * Double(timebase.denom) / Double(timebase.numer))
    }
}
