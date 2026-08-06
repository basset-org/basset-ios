@testable import Basset
import Foundation
import ObjectiveC
import Testing

/// The capability this domain rests on: **making a framework deliver a callback
/// the app never wrote.**
///
/// WebKit asks `respondsToSelector:` before sending
/// `webViewWebContentProcessDidTerminate:`, and most apps have never heard of it
/// — which is why a dead content process shows as a white rectangle and nothing
/// else. Wrapping cannot help, because there is nothing to wrap. Defining the
/// method is what turns the silence into a reading.
@Suite(.serialized)
struct WebKitDefineTests {
    /// An app that never heard of the callback. Defined on by the first test,
    /// and permanently so.
    private final class UnawareDelegate: NSObject {}

    /// The same, kept out of every swizzle so the absence stays observable.
    private final class UntouchedDelegate: NSObject {}

    /// And one that handles it.
    private final class AwareDelegate: NSObject {
        nonisolated(unsafe) static var received = 0

        @objc dynamic func webViewWebContentProcessDidTerminate(_ webView: AnyObject) {
            Self.received += 1
        }
    }

    /// A class that never had the method now has one, and reports `.implemented`
    /// so the instrument can say which of the two happened.
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
        // The framework's test for whether to deliver at all.
        #expect(UnawareDelegate().responds(to: ContentProcessTermination.didTerminate))

        UnawareDelegate().perform(
            ContentProcessTermination.didTerminate,
            with: NSObject()
        )
        #expect(observed == 1)
    }

    /// And where the app *did* write one, it is wrapped rather than replaced —
    /// an app that reloads on termination must go on reloading.
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

    /// Whether the app was listening is a finding in its own right: one that
    /// handles this usually reloads, and one that does not leaves the user
    /// looking at nothing.
    ///
    /// Its own untouched class, because **defining is permanent**. `Swizzle`
    /// releases observers but never removes an IMP, so a class this suite has
    /// defined the method on carries it for the rest of the process — which made
    /// an earlier version of this test pass or fail on ordering alone.
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

    /// The two selectors that must never be defined this way, named so a future
    /// reader finds the rule rather than rediscovering it: both take completion
    /// handlers, and calling one twice terminates the app.
    @Test func theHandlerCarryingCallbacksAreNotTouched() {
        let forbidden = ["decidePolicyForNavigationAction:decisionHandler:",
                         "didReceiveAuthenticationChallenge:completionHandler:"]

        #expect(forbidden
            .allSatisfy { $0 != ContentProcessTermination.didTerminate.description })
    }
}
