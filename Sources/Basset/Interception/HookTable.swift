import Foundation
import ObjectiveC

public final class HookTable: Sendable {
    public let swizzle: Swizzle
    public let registries: Registries

    public init(swizzle: Swizzle, registries: Registries) {
        self.swizzle = swizzle
        self.registries = registries
    }

    @discardableResult
    public func catchBirths<Caught: AnyObject>(
        of caught: Caught.Type,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(caught)
        return swizzle.after(owner, selector) { (_, argument: AnyObject?) in
            if let born = argument as? Caught {
                registry.add(born)
            }
        }
    }

    @discardableResult
    public func catchSelf<Caught: AnyObject>(
        of caught: Caught.Type,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(caught)
        return swizzle.after(owner, selector) { receiver in
            if let born = receiver as? Caught {
                registry.add(born)
            }
        }
    }

    /// For a chokepoint taking an argument — `-[AVCaptureSession addOutput:]` is one.
    @discardableResult
    public func catchSelf<Caught: AnyObject>(
        of caught: Caught.Type,
        atCallTaking selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(caught)
        return swizzle.after(owner, selector) { (receiver, _: AnyObject?) in
            if let born = receiver as? Caught {
                registry.add(born)
            }
        }
    }

    /// For one taking two — `-setSampleBufferDelegate:queue:` names who gets frames.
    @discardableResult
    public func catchSelf<Caught: AnyObject>(
        of caught: Caught.Type,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(caught)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if let born = receiver as? Caught {
                registry.add(born)
            }
        }
    }

    /// For a setter that can run after a follower already saw the object, unhooked.
    @discardableResult
    public func catchChanges<Caught: AnyObject>(
        of caught: Caught.Type,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(caught)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if let changed = receiver as? Caught {
                registry.announce(changed)
            }
        }
    }

    // The `class:`-keyed twins below track instances of a class only known at runtime —
    // never a compiled type — so a caller reaching a class through `objc_getClass` never
    // has to import the framework that declares it. `Caught` above always resolves to a
    // concrete bucket at compile time; these key that same bucket off the class itself.

    @discardableResult
    public func catchBirths(
        class caught: AnyClass,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: caught)
        return swizzle.after(owner, selector) { (_, argument: AnyObject?) in
            if let born = argument, born.isKind(of: caught) {
                registry.add(born)
            }
        }
    }

    @discardableResult
    public func catchSelf(
        class caught: AnyClass,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: caught)
        return swizzle.after(owner, selector) { receiver in
            if receiver.isKind(of: caught) {
                registry.add(receiver)
            }
        }
    }

    /// For a chokepoint taking an argument — `-[AVCaptureSession addOutput:]` is one.
    @discardableResult
    public func catchSelf(
        class caught: AnyClass,
        atCallTaking selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: caught)
        return swizzle.after(owner, selector) { (receiver, _: AnyObject?) in
            if receiver.isKind(of: caught) {
                registry.add(receiver)
            }
        }
    }

    /// For one taking two — `-setSampleBufferDelegate:queue:` names who gets frames.
    @discardableResult
    public func catchSelf(
        class caught: AnyClass,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: caught)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if receiver.isKind(of: caught) {
                registry.add(receiver)
            }
        }
    }

    /// For a setter that can run after a follower already saw the object, unhooked.
    @discardableResult
    public func catchChanges(
        class caught: AnyClass,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: caught)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if receiver.isKind(of: caught) {
                registry.announce(receiver)
            }
        }
    }
}
