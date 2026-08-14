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
    /// Guards a zero denom that would crash the host app on divide; 1:1 is real on arm64.
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

    /// Includes sleep time, unlike `now()` — for duration measured away from foreground.
    public func continuous() -> MonotonicTime {
        MonotonicTime(
            nanoseconds: mach_continuous_time() * UInt64(Self.timebase.numer)
                / UInt64(Self.timebase.denom)
        )
    }
}
