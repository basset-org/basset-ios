import Foundation

public final class Observation: NSObject {
    private struct State {
        weak var observed: NSObject?
        var attached = false
    }

    private let keyPath: String
    private let handler: (Any?) -> Void
    private let guarded: Mutex<State> = .init(State())

    /// False once the observed object is gone, which is what lets an owner
    /// drop registrations for objects the app has finished with.
    public var isAttached: Bool {
        guarded.withLock { $0.attached && $0.observed != nil }
    }

    deinit {
        detach()
    }

    private init(keyPath: String, handler: @escaping (Any?) -> Void) {
        self.keyPath = keyPath
        self.handler = handler
        super.init()
    }

    override public func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == self.keyPath else {
            return
        }

        handler(change?[.newKey])
    }

    public static func attach(
        to observed: NSObject,
        keyPath: String,
        initial: Bool = true,
        handler: @escaping (Any?) -> Void
    ) -> Observation {
        let observation = Observation(keyPath: keyPath, handler: handler)
        observation.guarded.withLock { state in
            state.observed = observed
            state.attached = true
        }

        var options: NSKeyValueObservingOptions = [.new]
        if initial {
            options.insert(.initial)
        }
        observed.addObserver(
            observation,
            forKeyPath: keyPath,
            options: options,
            context: nil
        )
        return observation
    }

    /// Removing an observer twice raises, and an ObjC exception cannot be caught
    /// from Swift — it ends the app this is a guest in. Claiming the removal
    /// under the lock is what makes the second caller a no-op rather than the
    /// last thing the process does.
    public func detach() {
        let claimed = guarded.withLock { state -> NSObject? in
            guard state.attached, let observed = state.observed else {
                return nil
            }

            state.attached = false
            return observed
        }
        guard let claimed else {
            return
        }

        claimed.removeObserver(self, forKeyPath: keyPath)
    }
}

/// Followers run on whichever thread the app called the swizzled method on and
/// on the runner queue during activation, at the same time, so the registrations
/// they collect cannot live in a bare array.
public final class Observations: @unchecked Sendable {
    private struct State {
        var attached: [Observation] = []
        var isStopped = false
    }

    private let guarded: Mutex<State> = .init(State())

    public var count: Int {
        guarded.withLock { $0.attached.count }
    }

    public init() {}

    /// Bounded by live objects rather than by how many the app has ever made: an
    /// app building one per screen visit would otherwise accumulate a
    /// registration per visit for the life of the request.
    /// Registering runs outside the lock. `Observation.attach` asks KVO to
    /// observe, which delivers the initial value before it returns, and running
    /// that under a lock this one is not allowed to re-enter turns a caller
    /// nobody has written yet into a trap.
    public func attach(_ make: () -> [Observation]) {
        guard !guarded.withLock({ $0.isStopped }) else {
            return
        }

        let made = make()
        let kept = guarded.withLock { state -> Bool in
            guard !state.isStopped else {
                return false
            }

            state.attached.removeAll { !$0.isAttached }
            state.attached.append(contentsOf: made)
            return true
        }
        guard !kept else {
            return
        }

        made.forEach { $0.detach() }
    }

    /// One way. A follower snapshotted before its request ended can still be in
    /// flight, and a registration it lands after this point is one nothing left
    /// alive will remove.
    public func detachAll() {
        let detaching = guarded.withLock { state -> [Observation] in
            state.isStopped = true
            let held = state.attached
            state.attached.removeAll()
            return held
        }

        detaching.forEach { $0.detach() }
    }
}
