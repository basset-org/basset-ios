@testable import Basset
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// The swizzling instruments, driven against **real UIKit objects**.
///
/// `Tests/Interception` already proves the `Swizzle` substrate hard: install
/// once, chain the original, refuse a mismatched shape, release per owner. It
/// does all of that against a controlled ObjC class written for the purpose,
/// which is the right way to test a substrate and says nothing about whether an
/// instrument aimed it at the right selector.
///
/// This closes that gap. A real `UIView` is laid out and a real
/// `UIViewController` is presented, and the assertion is that a reading came out
/// — so a `#selector` pointing at a method UIKit does not call, or an instrument
/// whose emit path is broken, fails here rather than on a user's device.
///
/// **Simulator only, structurally.** `canImport(UIKit)` is false on macOS, so
/// none of this compiles into the host rung at all.
/// `@MainActor` because UIKit means it: `makeKeyAndVisible` raises "Call must be
/// made on main thread", and swift-testing runs a test on whatever thread it
/// likes. The instruments themselves are indifferent — the swizzle fires on
/// whichever thread laid the view out — but the provocations are not.
@Suite(.serialized)
@MainActor
struct UIKitSwizzleWiringTests {
    /// Stands in for a screen. Named distinctly so the assertion is about this
    /// controller appearing rather than about anything the test host puts up.
    private final class ProbeViewController: UIViewController {}

    /// `layoutSubviews` is the hottest selector basset touches, and the whole
    /// instrument rests on the timing wrapper firing for a view the app made.
    @Test func layingOutARealViewIsCountedAndTimed() {
        let harness = InstrumentHarness<ViewLayoutPass>()
        harness.start()
        defer { harness.stop() }

        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        for _ in 0 ..< 5 {
            view.addSubview(UIView())
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }

        // Aggregated behind a one-second flush, so the wait is the instrument's
        // own interval rather than a guess.
        let reading = harness.waitForReading(timeout: 4)
        let passes = harness.value(.passCount, in: reading)

        #expect(passes != nil)
        #expect((passes.flatMap { UInt64($0) } ?? 0) > 0)
        // Nanoseconds as the clock gave them, so a no-op pass is still non-zero
        // and the window is carried for a rate to be computed against.
        #expect(reading?.components.contains { $0.id == .windowNanoseconds } == true)
        #expect(reading?.components.contains { $0.id == .peakNanoseconds } == true)
    }

    /// The swizzle is installed process-wide and never uninstalled, but its
    /// observers are released per owner. After teardown the IMP is still there
    /// and must have nobody left to tell.
    @Test func layoutStopsBeingCountedAfterTheInstrumentStops() {
        let harness = InstrumentHarness<ViewLayoutPass>()
        harness.start()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        view.layoutIfNeeded()
        harness.waitForReading(timeout: 4)
        harness.stop()
        harness.forget()

        for _ in 0 ..< 5 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        #expect(harness.readings.isEmpty)
    }

    /// `viewDidAppear` is called by UIKit rather than by the test, so this only
    /// passes if the appearance transition really ran — which is what makes it
    /// evidence about the selector rather than about the swizzle.
    @Test func aRealViewControllerAppearingIsReported() {
        let harness = InstrumentHarness<ViewControllerAppear>()
        harness.start()
        defer { harness.stop() }

        // No window. `beginAppearanceTransition` drives the appearance callbacks
        // itself, and a bare `UIWindow` traps in a test bundle with no host
        // application — the provocation should be the smallest thing that makes
        // UIKit call the selector.
        let controller = ProbeViewController()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        let reading = harness.waitForReading()
        #expect(harness.value(.viewControllerClass, in: reading)?
            .contains("ProbeViewController") == true)
    }

    /// The class name is read off the instance, so a subclass reports itself
    /// rather than `UIViewController` — which is the difference between a
    /// reading that names a screen and one that names the framework.
    @Test func theControllersOwnClassIsReportedRatherThanItsBase() {
        let harness = InstrumentHarness<ViewControllerAppear>()
        harness.start()
        defer { harness.stop() }

        let controller = ProbeViewController()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        let named = harness.value(.viewControllerClass, in: harness.waitForReading())
        #expect(named != "UIViewController")
    }
}
#endif
