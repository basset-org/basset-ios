@testable import Basset
import Foundation
import ObjectiveC
import Testing

/// Stands in for `CLLocationManager.setDelegate:` — class remembered at load, swizzled later.
@Suite(.serialized)
struct DelegateClassTests {
    /// `@objc dynamic` so the selector exists to be found and swizzled, like a real class would.
    private final class ProbeDelegate: NSObject {
        nonisolated(unsafe) static var received = 0

        @objc dynamic func locationManager(
            _ manager: AnyObject,
            didUpdateLocations locations: AnyObject
        ) {
            Self.received += 1
        }
    }

    /// And one that does not — the app whose location feature silently never starts.
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

    /// An app sets its delegate after the request that wants to watch it, same as `WeakRegistry`.
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

    /// A missing callback is the commonest cause of location silence — visible unswizzled.
    @Test func aClassMissingTheCallbackIsVisibleWithoutSwizzlingIt() {
        let selector = DelegateSilence.didUpdate

        #expect(class_getInstanceMethod(ProbeDelegate.self, selector) != nil)
        #expect(class_getInstanceMethod(SilentDelegate.self, selector) == nil)
    }

    /// The app's own implementation still runs after swizzling — must observe, not break it.
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
