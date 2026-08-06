import Foundation

/// What the main run loop last did, readable from another thread without
/// touching it. The observer runs on the loop being measured, so it does the
/// least possible: three relaxed stores and nothing else.
///
/// Timed from the last time the loop *parked* rather than the last time it
/// turned. A main thread running back-to-back callbacks turns constantly and is
/// frozen the whole time; one measured from the last turn reports it as healthy.
final class MainRunLoopHeartbeat: @unchecked Sendable {
    struct Beat {
        let idleAt: MonotonicTime
        let awake: Bool
        /// Turns taken since the loop last parked. One is a single long
        /// callback; many is a loop churning without ever going idle. Different
        /// bug, and the reading should not make the reader guess which.
        let turnsSinceIdle: UInt64
    }

    private let idleAt: UnsafeMutablePointer<UInt64> = .allocate(capacity: 1)
    private let turns: UnsafeMutablePointer<UInt64> = .allocate(capacity: 1)
    private let turnsAtIdle: UnsafeMutablePointer<UInt64> = .allocate(capacity: 1)
    private let awake: UnsafeMutablePointer<UInt8> = .allocate(capacity: 1)

    private let clock: Clock
    private let runLoop: CFRunLoop
    private var observer: CFRunLoopObserver?

    init(runLoop: CFRunLoop = CFRunLoopGetMain(), clock: Clock = Clock()) {
        self.runLoop = runLoop
        self.clock = clock
        Atomics.initialize(idleAt, clock.now().nanoseconds)
        Atomics.initialize(turns, 0)
        Atomics.initialize(turnsAtIdle, 0)
        Atomics.initialize(awake, 0)
    }

    deinit {
        stop()
        idleAt.deallocate()
        turns.deallocate()
        turnsAtIdle.deallocate()
        awake.deallocate()
    }

    func start() {
        guard observer == nil else {
            return
        }

        Atomics.storeRelaxed(idleAt, clock.now().nanoseconds)
        Atomics.storeReleasing(awake, 0)

        let watched: CFRunLoopActivity = [.afterWaiting, .beforeSources, .beforeWaiting]
        let created = CFRunLoopObserverCreateWithHandler(
            nil, watched.rawValue, true, 0
        ) { [idleAt, turns, turnsAtIdle, awake, clock] _, activity in
            if activity == .beforeWaiting {
                Atomics.storeRelaxed(turnsAtIdle, Atomics.loadRelaxed(turns))
                Atomics.storeRelaxed(idleAt, clock.now().nanoseconds)
                Atomics.storeReleasing(awake, 0)
                return
            }
            if activity == .afterWaiting {
                _ = Atomics.addRelaxed(turns, 1)
            }
            Atomics.storeReleasing(awake, 1)
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
        // Read awake first: a beat that parked between these loads reads as
        // awake with a fresh idle timestamp, which measures no hang. The other
        // order reads as awake with a stale one, which invents a long one.
        let parked = Atomics.loadRelaxed(awake) == 0
        let sinceIdle = Atomics.loadRelaxed(turns) - Atomics.loadRelaxed(turnsAtIdle)
        return Beat(
            idleAt: MonotonicTime(nanoseconds: Atomics.loadRelaxed(idleAt)),
            awake: !parked,
            turnsSinceIdle: sinceIdle
        )
    }
}
