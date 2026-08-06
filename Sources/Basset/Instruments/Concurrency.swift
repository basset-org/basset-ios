import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

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

/// The main run loop stopped returning to idle. Watched from a thread of its
/// own, because the one surface that cannot be asked how blocked it is, is the
/// blocked one.
final class MainThreadHang: StreamingInstrument {
    static let id: InstrumentWireID = .mainThreadHang
    static let entity = Entity.WireID.mainThread

    /// Two seconds to report, checked five times within it. The threshold is
    /// Sentry's and Apple's alike; the divisor bounds how late the report is
    /// without making the thread wake more often than it has to.
    private static let threshold: UInt64 = 2000000000
    private static let pollsPerThreshold: UInt64 = 5

    private let heartbeat: MainRunLoopHeartbeat
    private let watch: HangWatch
    private let clock: Clock
    private let foreground: AtomicStatus = .init()
    private var watchdog: Thread?
    private var lifecycle: [NSObjectProtocol] = []

    convenience init() {
        self.init(
            heartbeat: MainRunLoopHeartbeat(),
            clock: Clock(),
            threshold: Self.threshold
        )
    }

    init(heartbeat: MainRunLoopHeartbeat, clock: Clock, threshold: UInt64) {
        self.heartbeat = heartbeat
        self.clock = clock
        self.watch = HangWatch(threshold: threshold)
    }

    func observe(_ context: Context) {
        foreground.activate()
        followApplicationState()
        heartbeat.start()

        let interval = Double(watch.threshold) / Double(Self.pollsPerThreshold) /
            1000000000
        let watching = Thread { [heartbeat, watch, clock, foreground] in
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
                        foreground: foreground.isActive,
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
                    // While it is still stuck. Anything else the request enabled
                    // reads the frozen process here, not the recovered one.
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
        watching.start()
        watchdog = watching
    }

    func stopObserving() {
        watchdog?.cancel()
        watchdog = nil
        heartbeat.stop()
        lifecycle.forEach(NotificationCenter.default.removeObserver)
        lifecycle.removeAll()
    }

    /// Read from a flag rather than from `UIApplication`, whose state is only
    /// readable on the thread this instrument exists because it cannot reach.
    /// The flag goes stale in the safe direction: a backgrounded app whose
    /// notification never arrived is one whose main thread is busy anyway.
    private func followApplicationState() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycle = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [foreground] _ in foreground.activate() },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [foreground] _ in foreground.deactivate() },
        ]
        #endif
    }
}

/// How long a block waits before the main queue gets to it.
///
/// A different question from `concurrency.mainThreadHang`, and the pair is worth
/// ordering together. A hang is the main thread not reaching idle for seconds —
/// a freeze somebody notices. Latency is the queue running, but late: forty
/// milliseconds of wait, over and over, which no watchdog reports and which is
/// exactly what a dropped frame is made of.
///
/// The probe is a block timestamped when it is submitted and again when it runs,
/// so what is measured is the wait rather than the work. It is submitted once per
/// window and never re-submitted while one is outstanding, so a main queue that
/// has stopped answering accumulates one probe rather than a backlog that becomes
/// its own problem.
final class QueueLatency: StreamingInstrument, @unchecked Sendable {
    static let id: InstrumentWireID = .queueLatency
    static let entity = Entity.WireID.dispatchQueue

    private let clock: Clock = .init()
    private let lock: NSLock = .init()
    private var outstandingSince: MonotonicTime?
    private var samples: [UInt64] = []

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
        lock.withLock {
            outstandingSince = nil
            samples.removeAll()
        }
    }

    private func probe() {
        let submitted = clock.now()
        let alreadyWaiting = lock.withLock { () -> Bool in
            guard outstandingSince == nil else {
                return true
            }

            outstandingSince = submitted
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
            self.lock.withLock {
                self.outstandingSince = nil
                self.samples.append(waited)
            }
        }
    }

    private func report(over window: Context.FlushWindow, into out: inout Readings) {
        let (taken, waitingSince) = lock.withLock { () -> ([UInt64], MonotonicTime?) in
            defer { samples.removeAll() }
            return (samples, outstandingSince)
        }

        guard let worst = taken.max() else {
            // Nothing came back. Either no probe has completed yet, or the main
            // queue has not run one since it was submitted — and the second is a
            // finding rather than an absence, so the wait so far is reported as
            // the latency it already is.
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

/// What threads exist, what they are called, and what the scheduler is doing
/// with them — asked without stopping any of them.
///
/// The cheap half of the pair. `runtime.threadSnapshot` answers what each thread
/// is *executing*, and pays for it by suspending the whole process, so it only
/// runs when something has already gone wrong. This answers what each thread
/// *is*, from what the kernel already knows, and can be asked at any moment.
///
/// The finding it exists for is usually a count: a thread per request, a pool
/// that grew and never shrank, forty threads named after one library. Named
/// threads make that legible in a way a stack trace does not — the name is the
/// team that created them.
final class ThreadInventoryReading: SnapshotInstrument {
    static let id: InstrumentWireID = .threadInventory
    static let entity = Entity.WireID.thread

    /// A process with more threads than this has a finding of its own, and it is
    /// the count rather than the list. Emitting hundreds of rows would spend a
    /// request's whole budget describing the symptom.
    private static let ceiling = 96

    init() {}

    static func write(_ samples: [ThreadSample], into out: inout Readings) {
        guard let first = samples.first else {
            out.put(.mechanismStatus("unavailable: the task listed no threads"))
            return
        }

        // The count goes on the first row rather than in a row of its own, so a
        // reader that takes one entity still learns how many there were.
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
        out.put(.threadPriority(sample.currentPriority))
        // Only where it differs from the priority the thread asked for. Repeating
        // an unchanged base on every row would bury the one case worth seeing.
        if sample.isPriorityBoosted {
            out.put(.threadBasePriority(sample.basePriority))
        }
    }

    func reading(_ out: inout Readings) {
        Self.write(ThreadInventory.read(), into: &out)
    }
}
