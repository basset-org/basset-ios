@testable import Basset
import Foundation
import ObjectiveC
import Testing

/// The class-space alternative to proxying a delegate instance, tested against a
/// controlled ObjC class the way `Tests/Interception` tests the substrate.
///
/// The mechanism it stands in for is real: `CLLocationManager.setDelegate:` is
/// caught at load, the delegate's *class* is remembered, and the callback is
/// swizzled on that class when an instrument activates. Nothing here needs
/// CoreLocation, which is the point — a proxy would have to conform to
/// `CLLocationManagerDelegate` and so import it.
@Suite(.serialized)
struct DelegateClassTests {
    /// Stands in for an app's location delegate that answers the callback.
    /// `@objc dynamic` so the selector exists to be found and swizzled, which is
    /// what any Swift class conforming to the real protocol also produces.
    private final class ProbeDelegate: NSObject {
        nonisolated(unsafe) static var received = 0

        @objc dynamic func locationManager(
            _ manager: AnyObject,
            didUpdateLocations locations: AnyObject
        ) {
            Self.received += 1
        }
    }

    /// And one that does not — the app whose location feature silently never
    /// starts.
    private final class SilentDelegate: NSObject {}

    @Test func aDelegatesClassIsRememberedRatherThanTheDelegate() {
        let classes = DelegateClasses()
        classes.add(type(of: ProbeDelegate()))
        classes.add(type(of: ProbeDelegate()))

        // Two instances, one class. Nothing is retained and nothing can dangle.
        #expect(classes.all.count == 1)
        #expect(classes.all
            .first
            .map { NSStringFromClass($0) }?
            .contains("ProbeDelegate") == true)
    }

    /// The same contract `WeakRegistry` carries: an app sets its delegate when a
    /// screen opens, which is usually after the request that wants to watch it.
    @Test func attachingReachesClassesSeenBeforeAndAfter() {
        let classes = DelegateClasses()
        classes.add(ProbeDelegate.self)

        var reached = [String]()
        classes.attachAndFollow { reached.append(NSStringFromClass($0)) }
        classes.add(SilentDelegate.self)

        #expect(reached.count == 2)
        #expect(reached.contains { $0.contains("ProbeDelegate") })
        #expect(reached.contains { $0.contains("SilentDelegate") })
    }

    @Test func aFollowerStopsHearingWhenItLetsGo() {
        let classes = DelegateClasses()
        var reached = 0
        let token = classes.attachAndFollow { _ in reached += 1 }
        classes.stopFollowing(token)
        classes.add(ProbeDelegate.self)

        #expect(reached == 0)
    }

    /// **The finding that makes the whole approach worth taking.** A delegate
    /// that never implements the callback is the commonest cause of location
    /// silence, and `class_getInstanceMethod` answers it without installing
    /// anything — where a proxy would have to be interrogated.
    @Test func aClassMissingTheCallbackIsVisibleWithoutSwizzlingIt() {
        let selector = DelegateSilence.didUpdate

        #expect(class_getInstanceMethod(ProbeDelegate.self, selector) != nil)
        #expect(class_getInstanceMethod(SilentDelegate.self, selector) == nil)
    }

    /// Swizzling the app's own class, and the app's implementation still runs.
    /// A delegate that stopped receiving its own callbacks would be basset
    /// breaking the app rather than observing it.
    @Test func theAppsOwnImplementationStillRunsAfterSwizzling() {
        let swizzle = Swizzle()
        var observed = 0
        ProbeDelegate.received = 0

        let outcome = swizzle.after(
            ProbeDelegate.self,
            DelegateSilence.didUpdate,
            takingTwoObjects: ()
        ) { _, _, _ in
            observed += 1
        }
        #expect(outcome == .installed || outcome == .joinedExisting)

        let delegate = ProbeDelegate()
        delegate.locationManager(NSObject(), didUpdateLocations: NSArray())

        #expect(observed == 1)
        #expect(ProbeDelegate.received == 1)
        swizzle.releaseObservers()
    }
}
