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
    public func trackArgument<Tracked: AnyObject>(
        of tracked: Tracked.Type,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(tracked)
        return swizzle.after(owner, selector) { (_, argument: AnyObject?) in
            if let object = argument as? Tracked {
                registry.add(object)
            }
        }
    }

    @discardableResult
    public func trackSelf<Tracked: AnyObject>(
        of tracked: Tracked.Type,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(tracked)
        return swizzle.after(owner, selector) { receiver in
            if let object = receiver as? Tracked {
                registry.add(object)
            }
        }
    }

    /// For a chokepoint taking an argument — `-[AVCaptureSession addOutput:]` is one.
    @discardableResult
    public func trackSelf<Tracked: AnyObject>(
        of tracked: Tracked.Type,
        atCallTaking selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(tracked)
        return swizzle.after(owner, selector) { (receiver, _: AnyObject?) in
            if let object = receiver as? Tracked {
                registry.add(object)
            }
        }
    }

    /// For one taking two — `-setSampleBufferDelegate:queue:` names who gets frames.
    @discardableResult
    public func trackSelf<Tracked: AnyObject>(
        of tracked: Tracked.Type,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(tracked)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if let object = receiver as? Tracked {
                registry.add(object)
            }
        }
    }

    /// For a setter that can run after a follower already saw the object, unhooked.
    @discardableResult
    public func announceSelf<Tracked: AnyObject>(
        of tracked: Tracked.Type,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(tracked)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if let changed = receiver as? Tracked {
                registry.announce(changed)
            }
        }
    }

    // The `class:`-keyed twins below track instances of a class only known at runtime —
    // never a compiled type — so a caller reaching a class through `objc_getClass` never
    // has to import the framework that declares it. `Tracked` above always resolves to a
    // concrete bucket at compile time; these key that same bucket off the class itself.

    @discardableResult
    public func trackArgument(
        class tracked: AnyClass,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: tracked)
        return swizzle.after(owner, selector) { (_, argument: AnyObject?) in
            if let object = argument, object.isKind(of: tracked) {
                registry.add(object)
            }
        }
    }

    @discardableResult
    public func trackSelf(
        class tracked: AnyClass,
        at selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: tracked)
        return swizzle.after(owner, selector) { receiver in
            if receiver.isKind(of: tracked) {
                registry.add(receiver)
            }
        }
    }

    /// For a chokepoint taking an argument — `-[AVCaptureSession addOutput:]` is one.
    @discardableResult
    public func trackSelf(
        class tracked: AnyClass,
        atCallTaking selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: tracked)
        return swizzle.after(owner, selector) { (receiver, _: AnyObject?) in
            if receiver.isKind(of: tracked) {
                registry.add(receiver)
            }
        }
    }

    /// For one taking two — `-setSampleBufferDelegate:queue:` names who gets frames.
    @discardableResult
    public func trackSelf(
        class tracked: AnyClass,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: tracked)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if receiver.isKind(of: tracked) {
                registry.add(receiver)
            }
        }
    }

    /// For a setter that can run after a follower already saw the object, unhooked.
    @discardableResult
    public func announceSelf(
        class tracked: AnyClass,
        atCallTakingTwo selector: Selector,
        on owner: AnyClass?
    ) -> SwizzleOutcome {
        let registry = registries.registry(runtimeClass: tracked)
        return swizzle.after(owner, selector, takingTwoObjects: ()) { receiver, _, _ in
            if receiver.isKind(of: tracked) {
                registry.announce(receiver)
            }
        }
    }
}
