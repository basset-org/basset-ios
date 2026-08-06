import Foundation

public final class Observation: NSObject {
    private let keyPath: String
    private let handler: (Any?) -> Void
    private weak var observed: NSObject?
    private var attached = false

    /// False once the observed object is gone, which is what lets an owner
    /// drop registrations for objects the app has finished with.
    public var isAttached: Bool {
        attached && observed != nil
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
        observation.observed = observed
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
        observation.attached = true
        return observation
    }

    public func detach() {
        guard attached, let observed else {
            return
        }

        observed.removeObserver(self, forKeyPath: keyPath)
        attached = false
    }
}
