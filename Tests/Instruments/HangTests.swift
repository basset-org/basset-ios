@testable import Basset
import Foundation
import Testing

private let threshold: UInt64 = 2000000000
private let watch: HangWatch = .init(threshold: threshold)

private func beat(
    idleAt: UInt64,
    awake: Bool = true,
    turns: UInt64 = 1
) -> MainRunLoopHeartbeat.Beat {
    MainRunLoopHeartbeat.Beat(
        idleAt: MonotonicTime(nanoseconds: idleAt),
        awake: awake,
        turnsSinceIdle: turns
    )
}

private func poll(
    _ beat: MainRunLoopHeartbeat.Beat,
    now: UInt64,
    overshoot: TimeInterval = 0,
    foreground: Bool = true,
    debugged: Bool = false
) -> HangWatch.Poll {
    HangWatch.Poll(
        beat: beat,
        now: MonotonicTime(nanoseconds: now),
        overshoot: overshoot,
        foreground: foreground,
        debugged: debugged
    )
}

struct HangWatchTests {
    @Test func aLoopThatKeepsParkingIsQuiet() {
        var state = HangWatch.State()

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 9000000000, awake: false), now: 10000000000)
        )

        #expect(verdict == .quiet)
        #expect(state.busyStartedAt == nil)
    }

    @Test func busyUnderTheThresholdIsNotYetAHang() {
        var state = HangWatch.State()

        let verdict = watch.step(&state, poll(beat(idleAt: 9000000000), now: 10000000000))

        #expect(verdict == .quiet)
    }

    @Test func busyPastTheThresholdBegins() {
        var state = HangWatch.State()

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 5000000000, turns: 1), now: 8000000000)
        )

        #expect(verdict == .began(nanoseconds: 3000000000, turns: 1))
        #expect(state.busyStartedAt == MonotonicTime(nanoseconds: 5000000000))
    }

    /// One reading when it starts and one when it stops. A poll
    /// every 400ms through a 30s hang would otherwise send 75 readings saying
    /// the same thing.
    @Test func anOngoingHangIsNotReportedAgain() {
        var state = HangWatch.State()
        _ = watch.step(&state, poll(beat(idleAt: 5000000000), now: 8000000000))

        let verdict = watch.step(&state, poll(beat(idleAt: 5000000000), now: 9000000000))

        #expect(verdict == .quiet)
        #expect(state.busyStartedAt == MonotonicTime(nanoseconds: 5000000000))
    }

    @Test func parkingEndsItAndTheDurationIsMeasuredToTheIdleMoment() {
        var state = HangWatch.State()
        _ = watch.step(&state, poll(beat(idleAt: 5000000000), now: 8000000000))

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 9500000000, awake: false), now: 10000000000)
        )

        #expect(verdict == .ended(nanoseconds: 4500000000, turns: 1))
        #expect(state.busyStartedAt == nil, "the next hang starts from nothing")
    }

    @Test func theWorstTurnCountSeenIsTheOneReported() {
        var state = HangWatch.State()
        _ = watch.step(&state, poll(beat(idleAt: 5000000000, turns: 2), now: 8000000000))
        _ = watch.step(&state, poll(beat(idleAt: 5000000000, turns: 9), now: 9000000000))

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 9500000000, awake: false), now: 10000000000)
        )

        #expect(verdict == .ended(nanoseconds: 4500000000, turns: 9))
    }

    /// One long callback and a loop churning without going idle are both hangs
    /// and are not the same bug, so the count that separates them rides along.
    @Test func oneTurnAndManyTurnsAreBothHangsAndSayWhichTheyAre() {
        var blocked = HangWatch.State()
        var churning = HangWatch.State()

        let single = watch.step(
            &blocked,
            poll(beat(idleAt: 5000000000, turns: 1), now: 8000000000)
        )
        let repeated = watch.step(
            &churning,
            poll(beat(idleAt: 5000000000, turns: 40), now: 8000000000)
        )

        #expect(single == .began(nanoseconds: 3000000000, turns: 1))
        #expect(repeated == .began(nanoseconds: 3000000000, turns: 40))
    }

    /// The monotonic clock cannot tell a suspended process from a blocked one:
    /// both come back with a large elapsed time and no turns in between.
    @Test func aSuspendedProcessIsNotAHang() {
        var state = HangWatch.State()

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 5000000000), now: 60000000000, overshoot: 50)
        )

        #expect(verdict == .quiet)
        #expect(state.busyStartedAt == nil)
    }

    @Test func aBackgroundedAppIsNotReported() {
        var state = HangWatch.State()

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 5000000000), now: 8000000000, foreground: false)
        )

        #expect(verdict == .quiet)
    }

    @Test func aPausedDebuggerIsNotAHang() {
        var state = HangWatch.State()

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 5000000000), now: 8000000000, debugged: true)
        )

        #expect(verdict == .quiet)
    }

    /// A hang interrupted by a guard leaves a `began` with no `ended`. Emitting
    /// an `ended` here would put a duration on the wire that no clock measured.
    @Test func aHangInterruptedByAGuardEndsSilently() {
        var state = HangWatch.State()
        _ = watch.step(&state, poll(beat(idleAt: 5000000000), now: 8000000000))

        let verdict = watch.step(
            &state,
            poll(beat(idleAt: 5000000000), now: 9000000000, foreground: false)
        )

        #expect(verdict == .quiet)
        #expect(state.busyStartedAt == nil)
    }
}
