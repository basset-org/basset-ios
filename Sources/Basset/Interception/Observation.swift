import Foundation

public final class Observation: NSObject {
    private struct State {
        weak var observed: NSObject?
        var attached = false
        /// KVO delivers unretained; the deliberate self-cycle keeps delivery aimed at live memory.
        var keepAlive: Observation?
    }

    private let keyPath: String
    private let handler: (Any?) -> Void
    private let guarded: Mutex<State> = .init(State())

    /// False once observed is gone — lets an owner drop finished registrations.
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
            state.keepAlive = observation
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

    /// Removing twice raises an uncatchable exception; the lock makes a repeat a no-op.
    public func detach() {
        let claimed = guarded.withLock { state -> NSObject? in
            let observed = state.attached ? state.observed : nil
            state.attached = false
            state.keepAlive = nil
            return observed
        }
        guard let claimed else {
            return
        }

        claimed.removeObserver(self, forKeyPath: keyPath)
        // Removal does not wait for a delivery mid-flight; linger so it lands on live memory.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { _ = self }
    }
}

/// Followers run on the app's thread and the runner queue at once — never a bare array.
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

    /// Registers outside the lock — `Observation.attach` delivers KVO's initial value.
    public func attach(_ make: () -> [Observation]) {
        guard !guarded.withLock({ $0.isStopped }) else {
            return
        }

        let made = make()
        let (kept, finished) = guarded.withLock { state -> (Bool, [Observation]) in
            guard !state.isStopped else {
                return (false, [])
            }

            // One pass: a second look can answer differently, dropping one still holding itself.
            var finished = [Observation]()
            state.attached.removeAll { observation in
                guard !observation.isAttached else {
                    return false
                }

                finished.append(observation)
                return true
            }
            state.attached.append(contentsOf: made)
            return (true, finished)
        }

        // Detached even though their observed object is gone, or each would hold itself forever.
        finished.forEach { $0.detach() }
        guard !kept else {
            return
        }

        made.forEach { $0.detach() }
    }

    /// One way — a snapshotted follower can still land a registration after this runs.
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
