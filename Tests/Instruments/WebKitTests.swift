@testable import Basset
import Foundation
import ObjectiveC
import Testing

/// WebKit asks `respondsToSelector:` before delivering; defining the method is the only way in.
@Suite(.serialized)
struct WebKitDefineTests {
    /// An app that never heard of the callback; the first test defines it here permanently.
    private final class UnawareDelegate: NSObject {}

    /// Kept out of every swizzle so the absence stays observable.
    private final class UntouchedDelegate: NSObject {}

    private final class AwareDelegate: NSObject {
        nonisolated(unsafe) static var received = 0

        @objc dynamic func webViewWebContentProcessDidTerminate(_ webView: AnyObject) {
            Self.received += 1
        }
    }

    /// Reports `.implemented` so the instrument can say a method was added rather than wrapped.
    @Test func aCallbackTheClassLacksIsDefinedRatherThanRefused() {
        let swizzle = Swizzle()
        defer { swizzle.releaseObservers() }

        #expect(class_getInstanceMethod(
            UnawareDelegate.self,
            ContentProcessTermination.didTerminate
        ) == nil)

        var observed = 0
        let outcome = swizzle.afterOrDefine(
            UnawareDelegate.self,
            ContentProcessTermination.didTerminate
        ) { _, _ in observed += 1 }

        #expect(outcome == .implemented)
        #expect(UnawareDelegate().responds(to: ContentProcessTermination.didTerminate))

        UnawareDelegate().perform(
            ContentProcessTermination.didTerminate,
            with: NSObject()
        )
        #expect(observed == 1)
    }

    /// Wrapped rather than replaced — an app that reloads on termination must go on reloading.
    @Test func aCallbackTheClassHasIsWrappedAndStillRuns() {
        let swizzle = Swizzle()
        defer { swizzle.releaseObservers() }
        AwareDelegate.received = 0

        var observed = 0
        let outcome = swizzle.afterOrDefine(
            AwareDelegate.self,
            ContentProcessTermination.didTerminate
        ) { _, _ in observed += 1 }

        #expect(outcome == .installed || outcome == .joinedExisting)

        AwareDelegate().webViewWebContentProcessDidTerminate(NSObject())
        #expect(observed == 1)
        #expect(AwareDelegate.received == 1)
    }

    /// `Swizzle` never removes an IMP once defined, which made an earlier version order-dependent.
    @Test func whetherTheAppWasAlreadyListeningIsKnowableBeforeTouchingIt() {
        #expect(class_getInstanceMethod(
            AwareDelegate.self,
            ContentProcessTermination.didTerminate
        ) != nil)
        #expect(class_getInstanceMethod(
            UntouchedDelegate.self,
            ContentProcessTermination.didTerminate
        ) == nil)
    }

    /// Both take completion handlers; calling one twice terminates the app.
    @Test func theHandlerCarryingCallbacksAreNotTouched() {
        let forbidden = ["decidePolicyForNavigationAction:decisionHandler:",
                         "didReceiveAuthenticationChallenge:completionHandler:"]

        #expect(forbidden
            .allSatisfy { $0 != ContentProcessTermination.didTerminate.description })
    }
}
