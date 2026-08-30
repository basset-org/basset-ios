import BassetEntityComponent
import Foundation

/// One value under a lock — a repeating timer's @Sendable closure can't capture a var.
final class Mutable<Value>: @unchecked Sendable {
    private let guarded: Mutex<Value>

    init(_ value: Value) {
        guarded = .init(value)
    }

    /// The previous value, replaced by this one, in a single step.
    func take(_ next: Value) -> Value {
        guarded.withLock { value in
            let previous = value
            value = next
            return previous
        }
    }
}

public final class Context: @unchecked Sendable {
    /// How long a reading's counts actually accumulated — not the interval asked for.
    public struct FlushWindow: Sendable {
        public let nanoseconds: UInt64

        public var seconds: Double {
            Double(nanoseconds) / 1000000000
        }
    }

    public let clock: Clock = .init()
    public let swizzle: Swizzle
    public let registries: Registries
    public let tally: Tally

    let status: AtomicStatus

    private let sink: @Sendable (Entity) -> Void
    /// Carries the raising activation's status so a late fault attributes correctly.
    private let raise: @Sendable (FaultKind, UInt32, AtomicStatus) -> Void
    private let timerQueue: DispatchQueue
    private let lock: NSLock = .init()
    private var timers: [DispatchSourceTimer] = []
    private var unfollows: [() -> Void] = []
    private var lastEmitted: [String: Int] = [:]

    public var isActive: Bool {
        status.isActive
    }

    public var hotPath: HotPath {
        HotPath(tally: tally, clock: clock, status: status)
    }

    init(
        status: AtomicStatus,
        swizzle: Swizzle,
        registries: Registries,
        timerQueue: DispatchQueue,
        tallySlots: Int = 4,
        sink: @escaping @Sendable (Entity) -> Void,
        raise: @escaping @Sendable (FaultKind, UInt32, AtomicStatus) -> Void = { _, _, _ in }
    ) {
        tally = Tally(slots: tallySlots)
        self.status = status
        self.swizzle = swizzle
        self.registries = registries
        self.timerQueue = timerQueue
        self.sink = sink
        self.raise = raise
    }

    /// Something other instruments may care about; runs on the caller's own thread. `id`
    /// carries onto every contributor's readings as `faultId`, so this fault's own reading and
    /// whatever it triggers stay related without either instrument's code doing the linking.
    public func fault(_ kind: FaultKind, _ id: UInt32) {
        guard status.isActive else {
            return
        }

        raise(kind, id, status)
    }

    public func registry<Tracked: AnyObject>(_ type: Tracked.Type) -> [Tracked] {
        registries.registry(type).all
    }

    /// Attach to every instance already made and every one made while this stays active.
    public func follow<Tracked: AnyObject>(
        _ type: Tracked.Type,
        _ attach: @escaping (Tracked, UInt32) -> Void
    ) {
        let registry = registries.registry(type)
        let token = registry.attachAndFollow(attach)
        lock.lock()
        unfollows.append { registry.stopFollowing(token) }
        lock.unlock()
    }

    /// The `follow<Tracked>` above for a class only known at runtime — never a compiled
    /// type — so tracking a framework's instances never requires importing it.
    public func follow(
        class trackedClass: AnyClass,
        _ attach: @escaping (AnyObject, UInt32) -> Void
    ) {
        let registry = registries.registry(runtimeClass: trackedClass)
        let token = registry.attachAndFollow(attach)
        lock.lock()
        unfollows.append { registry.stopFollowing(token) }
        lock.unlock()
    }

    /// Where an instance tracked through `follow(class:)` was first created from.
    public func callers(class trackedClass: AnyClass, instance: UInt32) -> [UInt64] {
        registries.registry(runtimeClass: trackedClass).callers(ofInstance: instance)
    }

    public func deliver(_ readings: Readings) {
        guard status.isActive, !readings.isEmpty else {
            return
        }

        sink(readings.build())
        readings.additionalEntities().forEach(sink)
    }

    public func emit(_ entity: Entity.ID, _ build: (inout Readings) -> Void) {
        guard status.isActive else {
            return
        }

        var readings = Readings(entity)
        build(&readings)
        deliver(readings)
    }

    /// For state, never a sample — emitted only when changed from the last one sent.
    public func emitIfChanged(
        _ entity: Entity.ID,
        of subject: String = "",
        _ build: (inout Readings) -> Void
    ) {
        guard status.isActive else {
            return
        }

        var readings = Readings(entity)
        build(&readings)
        guard !readings.isEmpty else {
            return
        }

        let record = readings.build()
        let key = "\(record.id.rawValue)/\(subject)"
        let fingerprint = record.fingerprint

        lock.lock()
        let unchanged = lastEmitted[key] == fingerprint
        lastEmitted[key] = fingerprint
        lock.unlock()

        guard !unchanged else {
            return
        }

        sink(record)
        readings.additionalEntities().forEach(sink)
    }

    public func flush(
        every interval: Duration,
        into entity: Entity.ID,
        _ body: @escaping (inout Readings, FlushWindow) -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let seconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds, repeating: seconds)

        let clock = self.clock
        let opened = Mutable(clock.now())
        let fire = { [weak self] in
            guard let self, self.status.isActive else {
                return
            }

            let now = clock.now()
            let window = FlushWindow(nanoseconds: now.nanoseconds - opened.take(now)
                .nanoseconds)
            self.emit(entity) { out in body(&out, window) }
        }
        timer.setEventHandler(handler: fire)
        timer.activate()

        // A reading right away, since a caller waiting on activation should not sit through a
        // whole period for the first one; the periodic schedule above still anchors the first
        // full window, so a burst posted at activation keeps landing in one flush rather than
        // splitting across an empty immediate tick and the next.
        fire()

        lock.lock()
        timers.append(timer)
        lock.unlock()
    }

    /// Only while active — a hook installed after teardown would never be released.
    func installIfActive(_ install: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard status.isActive else {
            return false
        }

        install()
        return true
    }

    func teardown() {
        lock.lock()
        let running = timers
        let releasing = unfollows
        timers.removeAll()
        unfollows.removeAll()
        // Forgotten with activation — the next run re-establishes state, not a repeat.
        lastEmitted.removeAll()
        // Under the lock, unlike cancel/unfollow below, which can re-enter the context.
        swizzle.releaseObservers()
        lock.unlock()

        running.forEach { $0.cancel() }
        releasing.forEach { $0() }
    }
}
