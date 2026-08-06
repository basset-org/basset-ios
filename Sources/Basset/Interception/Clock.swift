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
    /// Read once, and never with a zero denominator: dividing by what a system
    /// call left in a struct it may not have filled takes the host app down, and
    /// this runs in an app that asked for a reading rather than for a crash.
    ///
    /// One-to-one is the fallback because it is the real ratio on every arm64
    /// device — the only place the sleep-inclusive clock is read — so the guard
    /// costs nothing where it applies and degrades to raw ticks where it cannot.
    private static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return mach_timebase_info_data_t(numer: 1, denom: 1)
        }

        return timebase
    }()

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
        MonotonicTime(
            nanoseconds: mach_continuous_time() * UInt64(Self.timebase.numer)
                / UInt64(Self.timebase.denom)
        )
    }
}
