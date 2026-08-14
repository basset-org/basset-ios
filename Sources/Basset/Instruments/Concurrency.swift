import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// A frozen main thread can mean suspended, debugged or backgrounded — only one is a real hang.
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
        /// Overshoot past the deadline — the monotonic clock can't tell sleeping from blocking.
        let overshoot: TimeInterval
        let foreground: Bool
        let debugged: Bool
    }

    let threshold: UInt64

    func step(_ state: inout State, _ poll: Poll) -> Verdict {
        // A hang ending backgrounded, suspended or debugged can't be measured, so nothing emits.
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

        // Parked: idle timestamp is the hang's end; running again, only known to within a poll.
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
    /// `P_TRACED` from the kernel — a paused debugger is the longest hang the SDK will ever see.
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

/// Watched from its own thread — the surface unable to say how blocked it is, is the blocked one.
final class MainThreadHang: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let thresholdMs: Int
    }

    static let id: InstrumentID = .mainThreadHang
    static let entity = Entity.ID.mainThread
    /// 2s, Apple's own hang threshold.
    static let defaultConfig: Config = .init(thresholdMs: 2000)

    /// Below the minimum the poll loop busy-spins; the maximum is a sane cap, not an overflow one.
    private static let minimumThresholdMs = 100
    private static let maximumThresholdMs = 60000
    private static let pollsPerThreshold: UInt64 = 5

    private let heartbeat: MainRunLoopHeartbeat
    private let watch: HangWatch
    private let clock: Clock
    private var watchdog: Thread?

    var thresholdNanoseconds: UInt64 {
        watch.threshold
    }

    /// Polled 5x within the threshold, to bound how late a report can be.
    convenience init(config: Config) {
        let clampedMs = min(
            max(config.thresholdMs, Self.minimumThresholdMs),
            Self.maximumThresholdMs
        )
        self.init(
            heartbeat: MainRunLoopHeartbeat(),
            clock: Clock(),
            threshold: UInt64(clampedMs) * 1000000
        )
    }

    init(heartbeat: MainRunLoopHeartbeat, clock: Clock, threshold: UInt64) {
        self.heartbeat = heartbeat
        self.clock = clock
        self.watch = HangWatch(threshold: threshold)
    }

    func observe(_ context: Context) {
        heartbeat.start()

        let interval = Double(watch.threshold) / Double(Self.pollsPerThreshold) /
            1000000000
        let watching = Thread { [heartbeat, watch, clock] in
            var state = HangWatch.State()

            while !Thread.current.isCancelled {
                let deadline = Date().addingTimeInterval(interval)
                Thread.sleep(forTimeInterval: interval)
                guard context.isActive else {
                    continue
                }

                let verdict = watch.step(
                    &state,
                    HangWatch.Poll(
                        beat: heartbeat.read(),
                        now: clock.now(),
                        overshoot: Date().timeIntervalSince(deadline),
                        foreground: ApplicationPresence.isForeground,
                        debugged: Debugger.isAttached
                    )
                )

                switch verdict {
                case .quiet:
                    continue
                case .began(let nanoseconds, let turns):
                    context.emit { out in
                        out.put(.hangNanoseconds(nanoseconds))
                        out.put(.hangResolved(false))
                        out.put(.runLoopTurnCount(turns))
                    }
                    // While still stuck — anything else enabled here reads the frozen process.
                    context.fault(.hang)
                case .ended(let nanoseconds, let turns):
                    context.emit { out in
                        out.put(.hangNanoseconds(nanoseconds))
                        out.put(.hangResolved(true))
                        out.put(.runLoopTurnCount(turns))
                    }
                }
            }
        }
        watching.name = QueueLabel.mainThreadHang
        // Default QoS is what a hang starves first — this thread has to win that contention.
        watching.qualityOfService = .userInteractive
        watching.start()
        watchdog = watching
    }

    func stopObserving() {
        watchdog?.cancel()
        watchdog = nil
        heartbeat.stop()
    }
}

/// Waits, not work: a block timestamped at submit and run, once per window, never backlogged.
final class QueueLatency: Streamable, PlainInstrument, @unchecked Sendable {
    private struct State {
        var outstandingSince: MonotonicTime?
        var samples: [UInt64] = []
    }

    static let id: InstrumentID = .queueLatency
    static let entity = Entity.ID.dispatchQueue

    private let clock: Clock = .init()
    private let guarded: Mutex<State> = .init(State())

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self else {
                return
            }

            self.report(over: window, into: &out)
            self.probe()
        }
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
    }

    private func probe() {
        let submitted = clock.now()
        let alreadyWaiting = guarded.withLock { state -> Bool in
            guard state.outstandingSince == nil else {
                return true
            }

            state.outstandingSince = submitted
            return false
        }
        guard !alreadyWaiting else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let waited = self.clock.now().nanoseconds &- submitted.nanoseconds
            self.guarded.withLock { state in
                state.outstandingSince = nil
                state.samples.append(waited)
            }
        }
    }

    private func report(over window: Context.FlushWindow, into out: inout Readings) {
        let (taken, waitingSince) = guarded
            .withLock { state -> ([UInt64], MonotonicTime?) in
                defer { state.samples.removeAll() }
                return (state.samples, state.outstandingSince)
            }

        guard let worst = taken.max() else {
            // Still waiting is a finding, not an absence — the wait so far is the latency.
            guard let waitingSince else {
                return
            }

            out.put(.queueLabel("main"))
            out
                .put(.queueLatencyNanoseconds(clock.now().nanoseconds &- waitingSince
                        .nanoseconds))
            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.mechanismStatus("still waiting"))
            return
        }

        out.put(.queueLabel("main"))
        out.put(.queueLatencyNanoseconds(worst))
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.occurrenceCount(UInt64(taken.count)))
    }
}

/// Cheap half of the pair: what a thread is, from the kernel — not what it runs, no suspension.
final class ThreadInventoryReading: Snapshotable, PlainInstrument {
    static let id: InstrumentID = .threadInventory
    static let entity = Entity.ID.thread

    /// Past this the finding is the count itself — hundreds of rows would spend the whole budget.
    private static let ceiling = 96

    init() {}

    static func write(_ samples: [ThreadSample], into out: inout Readings) {
        guard let first = samples.first else {
            out.put(.mechanismStatus("unavailable: the task listed no threads"))
            return
        }

        // Count rides the first row, not its own row, so reading one entity still learns the total.
        put(first, of: samples.count, into: &out)
        for sample in samples.dropFirst(1).prefix(ceiling - 1) {
            out.also(Self.entity) { sibling in put(
                sample,
                of: samples.count,
                into: &sibling
            ) }
        }

        guard samples.count > ceiling else {
            return
        }

        out.also(Self.entity) { sibling in
            sibling.put(.occurrenceCount(UInt64(samples.count)))
            sibling.put(.mechanismStatus("truncated: \(samples.count - ceiling) more"))
        }
    }

    private static func put(
        _ sample: ThreadSample,
        of total: Int,
        into out: inout Readings
    ) {
        out.put(.threadIndex(UInt32(sample.index)))
        out.put(.threadIdentifier(sample.identifier))
        out.put(.threadRunState(sample.runState))
        out.put(.threadIsMain(sample.isMain))
        out.put(.occurrenceCount(UInt64(total)))

        if !sample.name.isEmpty {
            out.put(.threadName(sample.name))
        }
        if sample.isIdle {
            out.put(.threadIdle(true))
        }
        out.put(.cpuUsageRatio(sample.cpuUsageRatio))
        out.put(.cpuNanoseconds(sample.cpuNanoseconds))
        // The pair only, no verdict — per-class base priorities aren't established on a phone.
        out.put(.threadPriority(sample.currentPriority))
        out.put(.threadRequestedQos(sample.requestedQos))
    }

    func reading(_ out: inout Readings) {
        Self.write(ThreadInventory.read(), into: &out)
    }
}
