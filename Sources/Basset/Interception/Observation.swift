import Foundation

public final class Observation: NSObject {
    private let keyPath: String
    private let handler: (Any?) -> Void
    private let lock: NSLock = .init()
    private weak var observed: NSObject?
    private var attached = false

    /// False once the observed object is gone, which is what lets an owner
    /// drop registrations for objects the app has finished with.
    public var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attached && observed != nil
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
        observation.lock.lock()
        observation.observed = observed
        observation.attached = true
        observation.lock.unlock()

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
        lock.lock()
        guard attached, let observed else {
            lock.unlock()
            return
        }

        attached = false
        lock.unlock()

        observed.removeObserver(self, forKeyPath: keyPath)
    }
}

/// Followers run on whichever thread the app called the swizzled method on and
/// on the runner queue during activation, at the same time, so the registrations
/// they collect cannot live in a bare array.
public final class Observations: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var attached: [Observation] = []
    private var isStopped = false

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return attached.count
    }

    public init() {}

    /// Bounded by live objects rather than by how many the app has ever made: an
    /// app building one per screen visit would otherwise accumulate a
    /// registration per visit for the life of the request.
    public func attach(_ make: () -> [Observation]) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else {
            return
        }

        attached.removeAll { !$0.isAttached }
        attached.append(contentsOf: make())
    }

    /// One way. A follower snapshotted before its request ended can still be in
    /// flight, and a registration it lands after this point is one nothing left
    /// alive will remove.
    public func detachAll() {
        lock.lock()
        isStopped = true
        let detaching = attached
        attached.removeAll()
        lock.unlock()

        detaching.forEach { $0.detach() }
    }
}
