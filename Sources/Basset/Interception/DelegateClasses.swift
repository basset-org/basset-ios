import Foundation
import ObjectiveC

/// Swizzles the delegate class, not an instance — no protocol import, no NSProxy cost.
public final class DelegateClasses: @unchecked Sendable {
    private struct State {
        var seen: [ObjectIdentifier: AnyClass] = [:]
        var arrivals: [Int: (AnyClass) -> Void] = [:]
        var nextToken = 0
    }

    private let guarded: Mutex<State> = .init(State())

    public var all: [AnyClass] {
        guarded.withLock { Array($0.seen.values) }
    }

    public init() {}

    public func add(_ delegateClass: AnyClass) {
        let key = ObjectIdentifier(delegateClass)
        let waiting = guarded.withLock { state -> [(AnyClass) -> Void]? in
            guard state.seen[key] == nil else {
                return nil
            }

            state.seen[key] = delegateClass
            return Array(state.arrivals.values)
        }
        guard let waiting else {
            return
        }

        waiting.forEach { $0(delegateClass) }
    }

    /// Every class tracked so far, and every one tracked from here on.
    @discardableResult
    public func attachAndFollow(_ attach: @escaping (AnyClass) -> Void) -> Int {
        let (existing, token) = guarded.withLock { state -> ([AnyClass], Int) in
            state.nextToken += 1
            state.arrivals[state.nextToken] = attach
            return (Array(state.seen.values), state.nextToken)
        }

        existing.forEach(attach)
        return token
    }

    public func stopFollowing(_ token: Int) {
        guarded.withLock { $0.arrivals.removeValue(forKey: token) }
    }
}

public extension HookTable {
    /// Installed at load — no public API lists a framework's live delegate instances.
    @discardableResult
    func trackDelegateClass(at selector: Selector,
                            on owner: AnyClass?) -> SwizzleOutcome
    {
        guard let owner else {
            return .classMissing
        }

        // Keyed on the owner class — CLLocationManager and CBCentralManager differ.
        let classes = registries.delegates(ObjectIdentifier(owner))
        return swizzle.after(owner, selector) { (_, delegate: AnyObject?) in
            guard let delegate else {
                return
            }

            // `classForCoder`, not the isa: KVO's dynamic subclass melts away with its observer.
            classes.add((delegate as? NSObject)?.classForCoder ?? type(of: delegate))
        }
    }

    /// For `setDelegate:queue:`-shaped setters, where the delegate is the first of two arguments.
    @discardableResult
    func trackDelegateClass(at selector: Selector,
                            on owner: AnyClass?,
                            takingTwoObjects: Void) -> SwizzleOutcome
    {
        guard let owner else {
            return .classMissing
        }

        let classes = registries.delegates(ObjectIdentifier(owner))
        return swizzle.after(owner, selector, takingTwoObjects: ()) {
            (_, delegate: AnyObject?, _) in
            guard let delegate else {
                return
            }

            classes.add((delegate as? NSObject)?.classForCoder ?? type(of: delegate))
        }
    }
}
