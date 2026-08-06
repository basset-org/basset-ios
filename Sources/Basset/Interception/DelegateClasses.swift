import Foundation
import ObjectiveC

/// The classes an app has used as a delegate, and a way to reach every one of
/// them — including the ones set before anybody asked.
///
/// **The alternative to proxying an instance.** Swizzling the app's own delegate
/// class gives three things a per-instance proxy does not:
///
/// - **Nothing has to be named.** A proxy must conform to the delegate protocol,
///   which means importing the framework that declares it — and for a
///   permission-gated framework that destroys the finding that an app which does
///   not link it does not use the feature. A selector is a string.
/// - **`forwardInvocation:` never runs.** An `NSProxy` builds an `NSInvocation`
///   per message, which is too expensive anywhere near a hot path.
/// - **A method the app never implemented is visible as an absence.**
///   `class_getInstanceMethod` returning nil says the delegate does not answer
///   that callback, which is the finding several instruments exist to report.
///
/// **Classes, not instances, so there are no weak references and no teardown.**
/// A class outlives the process. What this registry holds can never dangle, and
/// nothing here has to notice a delegate being deallocated.
///
/// The rule that goes with it: **wrap what exists, never add what does not.**
/// `class_addMethod` for a callback the app left unimplemented changes
/// `responds(to:)`, and frameworks consult `responds(to:)` to decide whether to
/// call at all — so adding one makes the system believe the app handles something
/// it ignores.
public final class DelegateClasses: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var seen: [ObjectIdentifier: AnyClass] = [:]
    private var arrivals: [Int: (AnyClass) -> Void] = [:]
    private var nextToken = 0

    public var all: [AnyClass] {
        lock.withLock { Array(seen.values) }
    }

    public init() {}

    public func add(_ delegateClass: AnyClass) {
        lock.lock()
        let key = ObjectIdentifier(delegateClass)
        guard seen[key] == nil else {
            lock.unlock()
            return
        }

        seen[key] = delegateClass
        let waiting = Array(arrivals.values)
        lock.unlock()

        waiting.forEach { $0(delegateClass) }
    }

    /// Every class caught so far, and every one caught from here on — the same
    /// guarantee `WeakRegistry.attachAndFollow` gives, for the same reason. An app
    /// sets its delegate when a screen opens, which is usually after the request
    /// that wants to watch it.
    @discardableResult
    public func attachAndFollow(_ attach: @escaping (AnyClass) -> Void) -> Int {
        lock.lock()
        let existing = Array(seen.values)
        nextToken += 1
        let token = nextToken
        arrivals[token] = attach
        lock.unlock()

        existing.forEach(attach)
        return token
    }

    public func stopFollowing(_ token: Int) {
        lock.withLock { arrivals.removeValue(forKey: token) }
    }
}

public extension HookTable {
    /// Catch the class of every delegate assigned through this setter.
    ///
    /// Installed at load, like every Shape A chokepoint: a delegate set before
    /// the request arrives is one the instrument could not otherwise name, since
    /// no public API enumerates live `CLLocationManager` or `CBCentralManager`
    /// instances. What is remembered is only the class, so the cost is one
    /// dictionary insert per distinct delegate class in the app — typically one.
    @discardableResult
    func catchDelegateClass(at selector: Selector,
                            on owner: AnyClass?) -> SwizzleOutcome
    {
        guard let owner else {
            return .classMissing
        }

        // Keyed on the class whose delegate it is: `CLLocationManager`'s
        // delegates are a different set from `CBCentralManager`'s.
        let classes = registries.delegates(ObjectIdentifier(owner))
        return swizzle.after(owner, selector) { (_, delegate: AnyObject?) in
            guard let delegate else {
                return
            }

            classes.add(type(of: delegate))
        }
    }
}
