import Foundation

public final class WeakRegistry<Tracked: AnyObject>: @unchecked Sendable {
    private final class Box {
        weak var tracked: Tracked?
        let instance: UInt32
        let callers: [UInt64]

        init(_ tracked: Tracked, _ instance: UInt32, _ callers: [UInt64]) {
            self.tracked = tracked
            self.instance = instance
            self.callers = callers
        }
    }

    private struct State {
        var boxes: [Box] = []
        var arrivals: [Int: (Tracked, UInt32) -> Void] = [:]
        var nextToken = 0
        var nextInstance: UInt32 = 0

        mutating func forgetReleased() {
            boxes.removeAll { $0.tracked == nil }
        }
    }

    private let guarded: Mutex<State> = .init(State())

    public var all: [Tracked] {
        guarded.withLock { state in
            state.forgetReleased()
            return state.boxes.compactMap(\.tracked)
        }
    }

    public var count: Int {
        all.count
    }

    /// Live objects with their number — an address is reused, so it can't key identity.
    public var tracked: [(object: Tracked, instance: UInt32)] {
        guarded.withLock { state in
            state.forgetReleased()
            return state.boxes.compactMap { box in box.tracked.map { ($0, box.instance) } }
        }
    }

    public init() {}

    /// This registry's number for an object the caller already holds.
    public func instance(of tracked: Tracked) -> UInt32? {
        guarded.withLock { state in
            state.forgetReleased()
            return state.boxes.first { $0.tracked === tracked }?.instance
        }
    }

    /// Where the object was first created from, innermost frame first. Empty once the
    /// object is gone, and for one that arrived through a path that does not record it.
    public func callers(ofInstance instance: UInt32) -> [UInt64] {
        guarded.withLock { state in
            state.forgetReleased()
            return state.boxes.first { $0.instance == instance }?.callers ?? []
        }
    }

    /// Answers the object's number whether it just got one or already had one.
    @discardableResult
    public func add(_ tracked: Tracked) -> UInt32 {
        // Answered before walking anything: a chokepoint that re-sees an object it already
        // holds pays nothing, and the walk itself stays outside the lock every caller waits on.
        if let known = guarded.withLock({ state -> UInt32? in
            state.boxes.first { $0.tracked === tracked }?.instance
        }) {
            return known
        }

        let callers = CallerStack.here()
        let (instance, waiting) = guarded
            .withLock { state -> (UInt32, [(Tracked, UInt32) -> Void]?) in
                state.forgetReleased()
                if let known = state.boxes.first(where: { $0.tracked === tracked }) {
                    return (known.instance, nil)
                }

                state.nextInstance += 1
                state.boxes.append(Box(tracked, state.nextInstance, callers))
                return (state.nextInstance, Array(state.arrivals.values))
            }

        waiting?.forEach { $0(tracked, instance) }
        return instance
    }

    /// `add` is silent for one already held, which is wrong once a delegate arrives late.
    public func announce(_ tracked: Tracked) {
        let known = guarded.withLock { state -> (UInt32, [(Tracked, UInt32) -> Void])? in
            state.forgetReleased()
            guard let box = state.boxes.first(where: { $0.tracked === tracked }) else {
                return nil
            }

            return (box.instance, Array(state.arrivals.values))
        }
        guard let (instance, waiting) = known else {
            add(tracked)
            return
        }

        waiting.forEach { $0(tracked, instance) }
    }

    /// Everything tracked so far, and everything tracked from here on.
    @discardableResult
    public func attachAndFollow(_ attach: @escaping (Tracked, UInt32) -> Void) -> Int {
        let (existing, token) = guarded
            .withLock { state -> ([(Tracked, UInt32)], Int) in
                state.forgetReleased()
                state.nextToken += 1
                state.arrivals[state.nextToken] = attach
                let live = state.boxes
                    .compactMap { box in box.tracked.map { ($0, box.instance) } }
                return (live, state.nextToken)
            }

        existing.forEach { attach($0.0, $0.1) }
        return token
    }

    /// By token — a registry is shared; deactivating one instrument silences only it.
    public func stopFollowing(_ token: Int) {
        guarded.withLock { $0.arrivals.removeValue(forKey: token) }
    }
}

public final class Registries: @unchecked Sendable {
    private struct State {
        var byType: [ObjectIdentifier: AnyObject] = [:]
        var byDelegateOwner: [ObjectIdentifier: DelegateClasses] = [:]
        var byRuntimeClass: [ObjectIdentifier: WeakRegistry<AnyObject>] = [:]
    }

    private let guarded: Mutex<State> = .init(State())

    public init() {}

    public func registry<Tracked: AnyObject>(_ type: Tracked
        .Type) -> WeakRegistry<Tracked>
    {
        guarded.withLock { state in
            let key = ObjectIdentifier(type)
            if let existing = state.byType[key] as? WeakRegistry<Tracked> {
                return existing
            }

            let created = WeakRegistry<Tracked>()
            state.byType[key] = created
            return created
        }
    }

    /// The instance-tracking counterpart of `registry(_:)` for a class only known at
    /// runtime — stored apart so a compile-time type and an `objc_getClass` lookup of the
    /// same class can never collide, and so a caller here never gets back a typed instance.
    public func registry(runtimeClass: AnyClass) -> WeakRegistry<AnyObject> {
        guarded.withLock { state in
            let key = ObjectIdentifier(runtimeClass)
            if let existing = state.byRuntimeClass[key] {
                return existing
            }

            let created = WeakRegistry<AnyObject>()
            state.byRuntimeClass[key] = created
            return created
        }
    }

    /// Class-space counterpart, stored apart so instance and delegate keys can't collide.
    func delegates(_ key: ObjectIdentifier) -> DelegateClasses {
        guarded.withLock { state in
            if let existing = state.byDelegateOwner[key] {
                return existing
            }

            let created = DelegateClasses()
            state.byDelegateOwner[key] = created
            return created
        }
    }
}
