import Foundation

/// The whole decision, as a transform over one poll. Kept apart from the thread
/// that drives it so the guards can be asserted as a table rather than by blocking
/// a real main thread.
///
/// Every guard exists because the same reading has two causes and only one is a
/// hang: a suspended process, a paused debugger and a backgrounded app all look
/// like a frozen main thread from a watchdog's side.
struct HangWatch {
    enum Verdict: Equatable {
        case quiet
        case began(nanoseconds: UInt64, turns: UInt64)
        case ended(nanoseconds: UInt64, turns: UInt64)
    }

    struct State: Equatable {
        var busyStartedAt: MonotonicTime?
        var turns: UInt64 = 0
    }

    struct Poll {
        let beat: MainRunLoopHeartbeat.Beat
        let now: MonotonicTime
        /// Wall-clock time beyond the deadline this poll was meant to wake at.
        /// The monotonic clock cannot tell sleeping from blocking, so the wall
        /// clock is asked a second question the first one cannot answer.
        let overshoot: TimeInterval
        let foreground: Bool
        let debugged: Bool
    }

    let threshold: UInt64

    func step(_ state: inout State, _ poll: Poll) -> Verdict {
        // A hang that ends while the app is backgrounded, suspended or paused
        // cannot be measured, so nothing is emitted for it. A `began` with no
        // `ended` says a hang started and the reading stopped; an `ended` built
        // from a clock that was not running would say something false.
        guard !poll.debugged, poll.foreground, poll.overshoot < seconds(threshold) else {
            state = State()
            return .quiet
        }

        let busy = poll.beat.awake ? poll.now.nanoseconds &- poll.beat.idleAt
            .nanoseconds : 0

        guard let startedAt = state.busyStartedAt else {
            guard poll.beat.awake, busy >= threshold else {
                return .quiet
            }

            state.busyStartedAt = MonotonicTime(nanoseconds: poll.now.nanoseconds &- busy)
            state.turns = poll.beat.turnsSinceIdle
            return .began(nanoseconds: busy, turns: poll.beat.turnsSinceIdle)
        }
        guard !poll.beat.awake || busy < threshold else {
            state.turns = max(state.turns, poll.beat.turnsSinceIdle)
            return .quiet
        }

        // The loop parked, so its idle timestamp is when the hang ended. Once
        // it is running again the end is only known to within a poll, and the
        // reading says the smaller, defensible number rather than the flattering
        // one.
        let endedAt = poll.beat.awake ? poll.now : poll.beat.idleAt
        let total = endedAt.nanoseconds > startedAt.nanoseconds
            ? endedAt.nanoseconds - startedAt.nanoseconds
            : 0
        let turns = state.turns
        state = State()
        return .ended(nanoseconds: total, turns: turns)
    }

    private func seconds(_ nanoseconds: UInt64) -> TimeInterval {
        TimeInterval(nanoseconds) / 1000000000
    }
}

enum Debugger {
    /// `P_TRACED` from the kernel's own record of this process. A paused
    /// debugger stops the main thread for as long as someone stares at a
    /// breakpoint, which is the longest hang the SDK will ever see and the least
    /// interesting one.
    static var isAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0
        else {
            return false
        }

        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
