@testable import Basset
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// `@MainActor`: `makeKeyAndVisible` raises off the main thread, unguaranteed by swift-testing.
@Suite(.serialized)
@MainActor
struct UIKitSwizzleWiringTests {
    /// Named distinctly, so the assertion is about this controller, not the test host's own.
    private final class ProbeViewController: UIViewController {}

    /// `layoutSubviews` is the hottest selector basset touches.
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

        // Aggregated behind a one-second flush, so the wait is the instrument's own interval.
        let reading = harness.waitForReading(timeout: 4)
        let passes = harness.value(.passCount, in: reading)

        #expect(passes != nil)
        #expect((passes.flatMap { UInt64($0) } ?? 0) > 0)
        // The window is carried too, so a rate can be computed against it.
        #expect(reading?.components.contains { $0.known == .windowNanoseconds } == true)
        #expect(reading?.components.contains { $0.known == .peakNanoseconds } == true)
    }

    /// The swizzle is never uninstalled; after teardown its IMP must have nobody left to tell.
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

    /// Called by UIKit, not the test — this only passes if the appearance transition really ran.
    @Test func aRealViewControllerAppearingIsReported() {
        let harness = InstrumentHarness<ViewControllerAppear>()
        harness.start()
        defer { harness.stop() }

        // No window — a bare `UIWindow` traps in a test bundle with no host application.
        let controller = ProbeViewController()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        let reading = harness.waitForReading()
        #expect(harness.value(.viewControllerClass, in: reading)?
            .contains("ProbeViewController") == true)
    }

    /// `UIEvent`/`UITouch` have no reachable constructor — only the swizzle outcome is provable.
    @Test func theTouchFunnelSelectorIsOneUIWindowHasAndTakesAnObject() {
        let swizzle = Swizzle()
        defer { swizzle.releaseObservers() }
        let outcome = swizzle
            .after(UIWindow.self, #selector(UIWindow.sendEvent(_:))) { (
                _,
                _: AnyObject?
            ) in
            }

        #expect(outcome != .selectorMissing)
        #expect(outcome == .installed || outcome == .joinedExisting)
    }

    /// Read off the instance, so a subclass reports itself rather than the framework's base class.
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

    /// Unlike a touch, `sendAction:to:for:` is callable directly — no synthetic `UITouch` needed.
    @Test func aRealSendActionIsReportedByTargetAndSelector() {
        final class Target: NSObject {
            @objc func handleTap() {}
        }

        let harness = InstrumentHarness<ControlAction>()
        harness.start()
        defer { harness.stop() }

        let control = UIControl()
        let target = Target()
        control.sendAction(#selector(Target.handleTap), to: target, for: nil)

        let reading = harness.waitForReading()
        #expect(harness.value(.methodName, in: reading) == "handleTap")
        #expect(harness.value(.methodClass, in: reading)?.contains("Target") == true)
    }

    /// A control with no target is a control configured with no handler — nothing to report.
    @Test func sendActionWithNoTargetReportsTheSelectorAndNoClass() {
        let harness = InstrumentHarness<ControlAction>()
        harness.start()
        defer { harness.stop() }

        let control = UIControl()
        control.sendAction(#selector(NSObject.description), to: nil, for: nil)

        let reading = harness.waitForReading()
        #expect(harness.value(.methodName, in: reading) == "description")
        #expect(reading?.components.contains { $0.known == .methodClass } != true)
    }

    /// A custom `UIGestureRecognizer` setting its own `state` is standard Swift practice — this
    /// exercises the real `setState:` call `GestureState` hooks, not just the selector's existence.
    @Test func aRecognizerEnteringItsOwnStateIsReported() {
        final class ProbeRecognizer: UIGestureRecognizer {
            func begin() {
                state = .began
            }
        }

        let harness = InstrumentHarness<GestureState>()
        harness.start()
        defer { harness.stop() }

        let recognizer = ProbeRecognizer()
        recognizer.begin()

        let reading = harness.waitForReading()
        #expect(harness.value(.gestureRecognizerState, in: reading) == "began")
        #expect(harness.value(.runtimeClassName, in: reading)?.contains("ProbeRecognizer") == true)
    }
}
#endif
