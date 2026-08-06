import Foundation

public struct MonotonicTime: Equatable, Comparable, Sendable {
    public let nanoseconds: UInt64

    public static func < (lhs: MonotonicTime, rhs: MonotonicTime) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func elapsedMilliseconds(since start: MonotonicTime) -> Float {
        guard nanoseconds > start.nanoseconds else {
            return 0
        }

        return Float(nanoseconds - start.nanoseconds) / 1000000
    }
}

public struct Clock: Sendable {
    public init() {}

    public func now() -> MonotonicTime {
        var uptime = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &uptime)
        return MonotonicTime(
            nanoseconds: UInt64(uptime.tv_sec) * 1000000000 + UInt64(uptime.tv_nsec)
        )
    }

    /// Elapsed time **including** the intervals the device spent asleep, which
    /// `now()` excludes.
    ///
    /// Most measurements here want `now()`: a hang is main-thread time, and a
    /// clock that ran while the device slept would call a sleeping phone a
    /// two-hour freeze. Duration away from the foreground is the opposite case —
    /// the device sleeps precisely while the app is backgrounded, so the clock
    /// that stops reports its smallest number exactly when the true one is
    /// largest.
    public func continuous() -> MonotonicTime {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = mach_continuous_time()
        return MonotonicTime(
            nanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        )
    }
}
