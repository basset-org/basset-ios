import BassetECS
import Foundation

/// One value, read and replaced under a lock. A repeating timer needs to
/// remember when it last ran, and the handler is a `@Sendable` closure that
/// cannot capture a `var`.
final class Mutable<Value>: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// The previous value, replaced by this one, in a single step.
    func take(_ next: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let previous = value
        value = next
        return previous
    }
}

public final class Context: @unchecked Sendable {
    /// How long the counts in a reading actually accumulated over.
    ///
    /// Not the interval the instrument asked for. A timer under load fires late,
    /// and a reading that says "passes" while implying "per second" is wrong by
    /// however late it was — six to thirteen seconds, where one instrument is
    /// starving the others. A rate the reader divides for itself cannot drift
    /// from the reading it describes.
    public struct FlushWindow: Sendable {
        public let nanoseconds: UInt64

        public var seconds: Double {
            Double(nanoseconds) / 1000000000
        }
    }

    public let clock: Clock = .init()
    public let swizzle: Swizzle
    public let registries: Registries
    public let tally: Tally = .init()

    let status: AtomicStatus

    private let instrumentName: String
    private let defaultEntity: Entity.WireID
    private let sink: @Sendable (Entity) -> Void
    /// Takes the raising activation's status as well as the kind. A fault can
    /// wait on the runner's lock while the request that raised it ends, and
    /// without a source there is nothing left to say which capture it belonged
    /// to — so it would be recorded against whichever one replaced it.
    private let raise: @Sendable (FaultKind, AtomicStatus) -> Void
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
        instrumentName: String,
        defaultEntity: Entity.WireID,
        status: AtomicStatus,
        swizzle: Swizzle,
        registries: Registries,
        timerQueue: DispatchQueue,
        sink: @escaping @Sendable (Entity) -> Void,
        raise: @escaping @Sendable (FaultKind, AtomicStatus) -> Void = { _, _ in }
    ) {
        self.instrumentName = instrumentName
        self.defaultEntity = defaultEntity
        self.status = status
        self.swizzle = swizzle
        self.registries = registries
        self.timerQueue = timerQueue
        self.sink = sink
        self.raise = raise
    }

    /// Something went wrong that other instruments may have something to say
    /// about. Whoever detected it does not know who those are — the runner
    /// asks whatever the request left active, so a fault carries context only
    /// when the request asked for it.
    ///
    /// Runs on the caller's thread on purpose: a fault is worth capturing while
    /// the process is still in the state that produced it, and a hop to a queue
    /// captures the recovery instead.
    public func fault(_ kind: FaultKind) {
        guard status.isActive else {
            return
        }

        raise(kind, status)
    }

    public func registry<Tracked: AnyObject>(_ type: Tracked.Type) -> [Tracked] {
        registries.registry(type).all
    }

    /// Attach to every one of these the app has already made, and to every one
    /// it makes while this instrument stays active. `registry(_:)` answers only
    /// the first half, which is a silent gap for anything the app builds when a
    /// screen opens.
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

    public func readings(_ entity: Entity.WireID? = nil) -> Readings {
        Readings(
            entity: entity ?? defaultEntity,
            instrumentName: instrumentName
        )
    }

    public func deliver(_ readings: Readings) {
        guard status.isActive, !readings.isEmpty else {
            return
        }

        sink(readings.sealed())
        readings.sealedSiblings().forEach(sink)
    }

    public func emit(_ entity: Entity.WireID? = nil, _ build: (inout Readings) -> Void) {
        guard status.isActive else {
            return
        }

        var readings = self.readings(entity)
        build(&readings)
        deliver(readings)
    }

    /// For a reading that reports a state rather than an event: emitted only
    /// when it differs from the last one this instrument sent about the same
    /// subject. KVO fires on every set and several UIKit notifications describe
    /// one transition, so an unchanged repeat is the mechanism talking rather
    /// than the app changing — and it costs a reading from a budget the request
    /// asked to be small.
    ///
    /// `subject` separates the things being described: two capture sessions
    /// alternating are not repeats of each other, and suppressing on the entity
    /// alone would drop every second one.
    ///
    /// Never for a sample. Three seconds of an unchanged frame rate are three
    /// facts, and the reading that shows a rate held steady is exactly the one
    /// worth having when asking why frames stopped.
    public func emitIfChanged(
        _ entity: Entity.WireID? = nil,
        of subject: String = "",
        _ build: (inout Readings) -> Void
    ) {
        guard status.isActive else {
            return
        }

        var readings = self.readings(entity)
        build(&readings)
        guard !readings.isEmpty else {
            return
        }

        let record = readings.sealed()
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
        readings.sealedSiblings().forEach(sink)
    }

    public func flush(
        every interval: Duration,
        into entity: Entity.WireID? = nil,
        _ body: @escaping (inout Readings, FlushWindow) -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let seconds = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds, repeating: seconds)

        let clock = self.clock
        let opened = Mutable(clock.now())
        timer.setEventHandler { [weak self] in
            guard let self, self.status.isActive else {
                return
            }

            let now = clock.now()
            let window = FlushWindow(nanoseconds: now.nanoseconds - opened.take(now)
                .nanoseconds)
            self.emit(entity) { out in body(&out, window) }
        }
        timer.activate()

        lock.lock()
        timers.append(timer)
        lock.unlock()
    }

    /// The runtime calls this on deactivate: an instrument stops observing, but
    /// the timers, registry subscriptions and hook observers it asked for belong
    /// to the context, so releasing them is not the instrument's to remember.
    /// Everything here is released outside the lock, so a handler running its
    /// last time cannot reach back into a context mid-teardown and deadlock.
    /// Installs while the request is still live, or not at all. Returns whether
    /// it ran.
    ///
    /// A hook deferred to a later run-loop turn can arrive after the request
    /// ended, and one installed after `teardown` released this context's
    /// observers is a hook nothing will ever release. Checking `isActive` first
    /// narrows that to a race; holding the same lock teardown holds closes it.
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
        // What was last said is forgotten with the activation that said it: the
        // first reading after an instrument starts again re-establishes the
        // state rather than being suppressed as a repeat of the last capture.
        lastEmitted.removeAll()
        // Under the lock, unlike the two below it: `installIfActive` takes this
        // same lock, so releasing here is what orders an install racing teardown
        // against it rather than letting it land behind. Cancelling a timer and
        // running an unfollow can re-enter this context, so those stay outside.
        swizzle.releaseObservers()
        lock.unlock()

        running.forEach { $0.cancel() }
        releasing.forEach { $0() }
    }
}
