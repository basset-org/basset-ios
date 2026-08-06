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

    private let lock: NSLock = .init()
    private var boxes: [Box] = []
    private var arrivals: [Int: (Tracked, UInt32) -> Void] = [:]
    private var nextToken = 0
    private var nextInstance: UInt32 = 0

    public var all: [Tracked] {
        lock.lock()
        defer { lock.unlock() }
        boxes.removeAll { $0.tracked == nil }
        return boxes.compactMap(\.tracked)
    }

    public var count: Int {
        all.count
    }

    /// Each live object with the number this registry gave it. An address is
    /// reused the moment the object at it is released, so anything keyed on
    /// `ObjectIdentifier` can hand a new object the state of a dead one. This
    /// number only ever counts up.
    public var tracked: [(object: Tracked, instance: UInt32)] {
        lock.lock()
        defer { lock.unlock() }
        boxes.removeAll { $0.tracked == nil }
        return boxes.compactMap { box in box.tracked.map { ($0, box.instance) } }
    }

    public init() {}

    public func add(_ tracked: Tracked) {
        lock.lock()
        boxes.removeAll { $0.tracked == nil }
        guard !boxes.contains(where: { $0.tracked === tracked }) else {
            lock.unlock()
            return
        }

        nextInstance += 1
        let instance = nextInstance
        boxes.append(Box(tracked, instance))
        let waiting = Array(arrivals.values)
        lock.unlock()

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
        lock.lock()
        boxes.removeAll { $0.tracked == nil }
        guard let box = boxes.first(where: { $0.tracked === tracked }) else {
            lock.unlock()
            add(tracked)
            return
        }

        let instance = box.instance
        let waiting = Array(arrivals.values)
        lock.unlock()

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
        lock.lock()
        boxes.removeAll { $0.tracked == nil }
        let existing = boxes.compactMap { box in box.tracked.map { ($0, box.instance) } }
        nextToken += 1
        let token = nextToken
        arrivals[token] = attach
        lock.unlock()

        existing.forEach { attach($0.0, $0.1) }
        return token
    }

    /// By token, because several instruments watch one framework class — the
    /// camera registry is shared by every `camera.*` instrument — and
    /// deactivating one must not silence its siblings.
    public func stopFollowing(_ token: Int) {
        lock.lock()
        arrivals.removeValue(forKey: token)
        lock.unlock()
    }
}

public final class Registries: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var byType: [ObjectIdentifier: AnyObject] = [:]
    private var byDelegateOwner: [ObjectIdentifier: DelegateClasses] = [:]

    public init() {}

    public func registry<Tracked: AnyObject>(_ type: Tracked
        .Type) -> WeakRegistry<Tracked>
    {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(type)
        if let existing = byType[key] as? WeakRegistry<Tracked> {
            return existing
        }
        let created = WeakRegistry<Tracked>()
        byType[key] = created
        return created
    }

    /// The class-space counterpart, keyed by whatever the caller is keying on.
    /// Separate storage from `registry(_:)` because the keys are the same kind
    /// of value — an `ObjectIdentifier` of a type — and a shared table would let
    /// `CLLocationManager`'s instance registry and its delegate classes collide.
    func delegates(_ key: ObjectIdentifier) -> DelegateClasses {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byDelegateOwner[key] {
            return existing
        }
        let created = DelegateClasses()
        byDelegateOwner[key] = created
        return created
    }
}
