@testable import Basset
import Foundation
import Testing

private final class Observation: @unchecked Sendable {
    var awake = false
    var busyNanoseconds: UInt64 = 0
    var turnsSinceIdle: UInt64 = 0
    var reads = 0
}

/// Reads the beat inline — a watcher thread would trip `ThreadWalker`'s thread cap.
private final class SelfSignallingSource {
    let heartbeat: MainRunLoopHeartbeat
    let clock: Clock
    let observed: Observation

    var source: CFRunLoopSource?
    var until: Date = .init()

    init(heartbeat: MainRunLoopHeartbeat, clock: Clock, observed: Observation) {
        self.heartbeat = heartbeat
        self.clock = clock
        self.observed = observed
    }

    func add(to loop: CFRunLoop, until deadline: Date) {
        until = deadline

        var context = CFRunLoopSourceContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        context.perform = { info in
            guard let info else {
                return
            }

            Unmanaged<SelfSignallingSource>.fromOpaque(info)
                .takeUnretainedValue()
                .recordAndSignal()
        }

        let created = CFRunLoopSourceCreate(nil, 0, &context)!
        source = created
        CFRunLoopAddSource(loop, created, .defaultMode)
        CFRunLoopSourceSignal(created)
    }

    private func recordAndSignal() {
        let beat = heartbeat.read()
        observed.reads += 1
        observed.awake = beat.awake
        observed.turnsSinceIdle = max(observed.turnsSinceIdle, beat.turnsSinceIdle)
        observed.busyNanoseconds = max(
            observed.busyNanoseconds,
            clock.now().nanoseconds &- beat.idleAt.nanoseconds
        )

        guard Date() < until, let source else {
            return
        }

        CFRunLoopSourceSignal(source)
    }
}

struct MainRunLoopHeartbeatTests {
    /// A beat still pointing at the park moment would report idle sleep time as busy time.
    @Test func timeSpentParkedIsNotCountedAsBusy() {
        let sleepSeconds: TimeInterval = 1
        let observed = Observation()
        let finished = DispatchSemaphore(value: 0)

        let running = Thread {
            let clock = Clock()
            let heartbeat = MainRunLoopHeartbeat(runLoop: CFRunLoopGetCurrent()!, clock: clock)
            heartbeat.start()

            Timer.scheduledTimer(withTimeInterval: sleepSeconds, repeats: false) { _ in
                let beat = heartbeat.read()
                observed.awake = beat.awake
                observed.turnsSinceIdle = beat.turnsSinceIdle
                observed.busyNanoseconds = clock.now().nanoseconds &- beat.idleAt.nanoseconds
            }
            RunLoop.current.run(until: Date().addingTimeInterval(sleepSeconds + 0.5))

            heartbeat.stop()
            finished.signal()
        }
        running.start()

        #expect(finished.wait(timeout: .now() + TestMachine.joinTimeout) == .success)
        #expect(observed.awake, "the beat was not read from inside a run loop callback")
        #expect(
            observed.busyNanoseconds < 500000000,
            "a loop parked for \(sleepSeconds)s woke and read as having been busy for it"
        )
        // A range, not equality — turns between wake and callback is the scheduler's business.
        #expect(
            observed.turnsSinceIdle >= 1 && observed.turnsSinceIdle < 50,
            "a single callback after a park took \(observed.turnsSinceIdle) turns"
        )
    }

    /// Skipped on a shared simulator — a starved core fails the join here, not the measurement.
    @Test(.enabled(if: !TestMachine.isSharedSimulator))
    func aLoopThatNeverParksCountsEveryTurnItTakes() {
        let churnSeconds: TimeInterval = 0.75
        let observed = Observation()
        let finished = DispatchSemaphore(value: 0)

        let running = Thread {
            let clock = Clock()
            let loop = CFRunLoopGetCurrent()!
            let heartbeat = MainRunLoopHeartbeat(runLoop: loop, clock: clock)
            heartbeat.start()

            let churn = SelfSignallingSource(
                heartbeat: heartbeat,
                clock: clock,
                observed: observed
            )
            churn.add(to: loop, until: Date().addingTimeInterval(churnSeconds))
            RunLoop.current.run(until: Date().addingTimeInterval(churnSeconds + 0.5))

            heartbeat.stop()
            finished.signal()
        }
        running.start()

        #expect(finished.wait(timeout: .now() + TestMachine.joinTimeout) == .success)
        #expect(observed.awake, "the loop parked while servicing back-to-back work")
        #expect(
            observed.reads > 100,
            "the source ran \(observed.reads) times, which is not a churn"
        )
        #expect(
            observed.turnsSinceIdle > 100,
            "a loop that never parked reported \(observed.turnsSinceIdle) turns"
        )
        // 50%, not stricter — 67% was a cliff a loaded machine fell off at 64%.
        let mostOfTheWindow = UInt64(churnSeconds * 0.5 * 1e9)
        #expect(
            observed.busyNanoseconds > mostOfTheWindow,
            "a loop busy for \(churnSeconds)s without an idle read as \(observed.busyNanoseconds)ns"
        )
    }
}
