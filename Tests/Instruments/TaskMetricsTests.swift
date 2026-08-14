@testable import Basset
import Foundation
import Testing

#if os(iOS)
/// No caller can construct a `URLSessionTaskMetrics`, so this settles the wiring instead.
@Suite(.serialized)
struct TaskMetricsTests {
    /// Conformance rather than a hand-pinned `@objc` name, so the runtime's own selector is used.
    private final class CollectingDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {}
    }

    /// The ordinary case: a delegate that never wrote the callback.
    private final class SilentDelegate: NSObject {}

    @Test func aDelegateClassSeenBeforeActivationIsReached() {
        let harness = InstrumentHarness<TaskMetrics>()
        TaskMetrics.delegateClasses(harness.registries).add(SilentDelegate.self)

        #expect(SilentDelegate().responds(to: TaskMetrics.didFinishCollecting) == false)
        harness.start()
        defer { harness.stop() }

        #expect(
            SilentDelegate().responds(to: TaskMetrics.didFinishCollecting),
            """
            a framework asks before it delivers, so a delegate that never wrote \
            the callback receives nothing until the method exists
            """
        )
    }

    @Test func aDelegateClassSeenAfterActivationIsReachedToo() {
        let harness = InstrumentHarness<TaskMetrics>()
        harness.start()
        defer { harness.stop() }

        TaskMetrics.delegateClasses(harness.registries).add(CollectingDelegate.self)

        #expect(CollectingDelegate().responds(to: TaskMetrics.didCompleteWithError))
    }

    /// The name the runtime knows is not the name Swift shows — a Swift literal finds nothing.
    @Test func theCollectingSelectorCarriesTheSuffixSwiftHides() {
        #expect(
            NSStringFromSelector(TaskMetrics.didFinishCollecting)
                == "URLSession:task:didFinishCollectingMetrics:"
        )
        #expect(CollectingDelegate().responds(to: TaskMetrics.didFinishCollecting))
    }

    /// Adding the callback here would make the framework assemble metrics nothing asked for.
    @Test func bassetsOwnDelegateIsNeverWatched() {
        let harness = InstrumentHarness<TaskMetrics>()
        harness.start()
        defer { harness.stop() }

        let session = URLSession(
            configuration: .ephemeral,
            delegate: RedirectRefusal.shared,
            delegateQueue: nil
        )
        TaskMetrics.trackSession(session, RedirectRefusal.shared, HookTable(
            swizzle: Swizzle(),
            registries: harness.registries
        ))

        #expect(
            TaskMetrics.delegateClasses(harness.registries).all.isEmpty,
            "basset's own delegate class was taken for an app's"
        )
        #expect(
            RedirectRefusal.shared.responds(to: TaskMetrics.didFinishCollecting) == false
        )
    }
}
#endif
