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
}
