import Foundation

/// Timed from the last idle instant, not the last turn, or churn reads as healthy.
final class MainRunLoopHeartbeat: @unchecked Sendable {
    struct Beat {
        let idleAt: MonotonicTime
        let awake: Bool
        /// Iterations since last parked — distinguishes one long callback from churn.
        let turnsSinceIdle: UInt64
    }

    /// The observer block retains this, so a callout racing invalidation still writes live memory.
    private final class Cells {
        let idleAt: UnsafeMutablePointer<UInt64> = .allocate(capacity: 1)
        let turns: UnsafeMutablePointer<UInt64> = .allocate(capacity: 1)
        let turnsAtIdle: UnsafeMutablePointer<UInt64> = .allocate(capacity: 1)
        let awake: UnsafeMutablePointer<UInt8> = .allocate(capacity: 1)

        init(clock: Clock) {
            Atomics.initialize(idleAt, clock.now().nanoseconds)
            Atomics.initialize(turns, 0)
            Atomics.initialize(turnsAtIdle, 0)
            Atomics.initialize(awake, 0)
        }

        deinit {
            idleAt.deallocate()
            turns.deallocate()
            turnsAtIdle.deallocate()
            awake.deallocate()
        }
    }

    private let cells: Cells
    private let clock: Clock
    private let runLoop: CFRunLoop
    private var observer: CFRunLoopObserver?

    init(runLoop: CFRunLoop = CFRunLoopGetMain(), clock: Clock = Clock()) {
        self.runLoop = runLoop
        self.clock = clock
        cells = Cells(clock: clock)
    }

    deinit {
        stop()
    }

    func start() {
        guard observer == nil else {
            return
        }

        Atomics.storeRelaxed(cells.idleAt, clock.now().nanoseconds)
        Atomics.storeReleasing(cells.awake, 0)

        let watched: CFRunLoopActivity = [.afterWaiting, .beforeSources, .beforeWaiting]
        let created = CFRunLoopObserverCreateWithHandler(
            nil, watched.rawValue, true, 0
        ) { [cells, clock] _, activity in
            if activity == .beforeWaiting {
                Atomics.storeRelaxed(cells.turnsAtIdle, Atomics.loadRelaxed(cells.turns))
                Atomics.storeRelaxed(cells.idleAt, clock.now().nanoseconds)
                Atomics.storeReleasing(cells.awake, 0)
                return
            }
            // Every non-park activity is a turn; counting only wake caps churn at one.
            _ = Atomics.addRelaxed(cells.turns, 1)
            // Idle right up to this instant — sleep itself must not count as work.
            if activity == .afterWaiting {
                Atomics.storeRelaxed(cells.idleAt, clock.now().nanoseconds)
            }
            Atomics.storeReleasing(cells.awake, 1)
        }
        CFRunLoopAddObserver(runLoop, created, .commonModes)
        observer = created
    }

    func stop() {
        guard let observer else {
            return
        }

        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
    }

    func read() -> Beat {
        // Read awake first, or the other load order can invent a hang from a stale time.
        let parked = Atomics.loadRelaxed(cells.awake) == 0
        // The main thread can park between these loads; clamp or the subtraction traps.
        let atIdle = Atomics.loadRelaxed(cells.turnsAtIdle)
        let turns = Atomics.loadRelaxed(cells.turns)
        return Beat(
            idleAt: MonotonicTime(nanoseconds: Atomics.loadRelaxed(cells.idleAt)),
            awake: !parked,
            turnsSinceIdle: turns >= atIdle ? turns - atIdle : 0
        )
    }
}
