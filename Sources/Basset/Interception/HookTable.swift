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

    /// The same, for a chokepoint that takes an argument. `-[AVCaptureSession
    /// addOutput:]` is one, and reaching it through the no-argument shape leaves
    /// AVFoundation reading its output from a register nothing set.
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

    /// And for one taking two. `-setSampleBufferDelegate:queue:` is where a video
    /// data output learns who receives its frames, which makes it the moment the
    /// output is worth holding on to.
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

    /// A call that changes something a follower already decided on. The delegate
    /// a video output delivers to is set through its own call, which the app may
    /// make before or after handing the output to a session — and a follower that
    /// saw the output first saw one with nothing to hook.
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
}
