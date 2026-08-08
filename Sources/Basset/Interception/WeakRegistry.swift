import Foundation

public final class WeakRegistry<Tracked: AnyObject>: @unchecked Sendable {
    private final class Box {
        weak var tracked: Tracked?
        let instance: UInt32

        init(_ tracked: Tracked, _ instance: UInt32) {
            self.tracked = tracked
            self.instance = instance
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

    /// Each live object with the number this registry gave it. An address is
    /// reused the moment the object at it is released, so anything keyed on
    /// `ObjectIdentifier` can hand a new object the state of a dead one. This
    /// number only ever counts up.
    public var tracked: [(object: Tracked, instance: UInt32)] {
        guarded.withLock { state in
            state.forgetReleased()
            return state.boxes.compactMap { box in box.tracked.map { ($0, box.instance) } }
        }
    }

    public init() {}

    public func add(_ tracked: Tracked) {
        let arrival = guarded.withLock { state -> (UInt32, [(Tracked, UInt32) -> Void])? in
            state.forgetReleased()
            guard !state.boxes.contains(where: { $0.tracked === tracked }) else {
                return nil
            }

            state.nextInstance += 1
            state.boxes.append(Box(tracked, state.nextInstance))
            return (state.nextInstance, Array(state.arrivals.values))
        }
        guard let (instance, waiting) = arrival else {
            return
        }

        waiting.forEach { $0(tracked, instance) }
    }

    /// The same object again, because something a follower needs has changed
    /// about it.
    ///
    /// `add` is silent for an object it already holds, which is right for
    /// arrival and wrong for a video output added to a session before it was
    /// told who receives its frames. The follower saw it while there was no
    /// delegate to hook, and nothing ever said otherwise — so a camera in that
    /// ordinary order reported no frames at all.
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

    /// Everything caught so far, and everything caught from here on. An
    /// instrument activated while the app is running has to reach both: the
    /// registry answers for objects born before the request, and this closure
    /// for the ones born after. Walking the registry alone silently misses every
    /// object the app creates once the request is live — which for a camera is
    /// most of them, because the session is built when the user opens the
    /// screen.
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

    /// By token, because several instruments watch one framework class — the
    /// camera registry is shared by every `camera.*` instrument — and
    /// deactivating one must not silence its siblings.
    public func stopFollowing(_ token: Int) {
        guarded.withLock { $0.arrivals.removeValue(forKey: token) }
    }
}

public final class Registries: @unchecked Sendable {
    private struct State {
        var byType: [ObjectIdentifier: AnyObject] = [:]
        var byDelegateOwner: [ObjectIdentifier: DelegateClasses] = [:]
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

    /// The class-space counterpart, keyed by whatever the caller is keying on.
    /// Separate storage from `registry(_:)` because the keys are the same kind
    /// of value — an `ObjectIdentifier` of a type — and a shared table would let
    /// `CLLocationManager`'s instance registry and its delegate classes collide.
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
