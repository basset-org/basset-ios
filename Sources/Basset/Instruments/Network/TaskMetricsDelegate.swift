#if os(iOS)
import Foundation

/// A task delegate that records and forwards. Concrete rather than NSProxy: the
/// same delegate receives didReceive data: on every chunk, and forwardInvocation:
/// builds an NSInvocation per message.
///
/// Installed at task creation and dormant until an activation hands it a context,
/// which is why these are themselves registered — walking a registry of proxies is
/// how the runtime reaches objects it created before any request existed.
///
/// Forwarding is not politeness. A task-level delegate takes precedence for
/// task-level messages, so anything this does not pass on is a message the app
/// stops receiving.
final class TaskMetricsDelegate: NSObject, URLSessionTaskDelegate,
    URLSessionDataDelegate
{
    /// Readable so `network.session.configuration` can describe the session
    /// this proxy was made for without installing a second chokepoint of its
    /// own. Weak throughout: basset never keeps an app's session alive.
    private(set) weak var session: URLSession?

    private let existing: (any URLSessionTaskDelegate)?
    private let lock: NSLock = .init()
    private var reporting: ((URLSessionTask, URLSessionTaskMetrics, String) -> Void)?
    private var failing: ((URLSessionTask, Error) -> Void)?

    /// Which delegate the metrics actually arrived on. The whole reason this
    /// instrument is shaped around a task delegate rather than a substituted
    /// session delegate is unproven until a real capture says so.
    private var forwardTarget: (any URLSessionTaskDelegate)? {
        existing ?? (session?.delegate as? URLSessionTaskDelegate)
    }

    init(session: URLSession?, existing: (any URLSessionTaskDelegate)?) {
        self.session = session
        self.existing = existing
        super.init()
    }

    /// Everything this type does not implement goes to whoever would have had it.
    override func forwardingTarget(for selector: Selector!) -> Any? {
        guard let target = forwardTarget, target.responds(to: selector) else {
            return super.forwardingTarget(for: selector)
        }

        return target
    }

    /// URLSession asks before it calls, so answering only for what this type
    /// declares would silence every optional method the app implemented.
    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) {
            return true
        }
        return forwardTarget?.responds(to: selector) ?? false
    }

    func report(
        into sink: @escaping (URLSessionTask, URLSessionTaskMetrics, String) -> Void,
        failures: @escaping (URLSessionTask, Error) -> Void
    ) {
        lock.withLock {
            reporting = sink
            failing = failures
        }
    }

    func stop() {
        lock.withLock {
            reporting = nil
            failing = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let sink = lock.withLock { reporting }
        sink?(task, metrics, "taskDelegate")
        forwardTarget?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }

    /// A failure and a set of metrics are different readings about the same task:
    /// metrics say what the transaction did, this says why it ended. A handover
    /// mid-request produces both.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let sink = lock.withLock { failing }
            sink?(task, error)
        }
        forwardTarget?.urlSession?(session, task: task, didCompleteWithError: error)
    }
}
#endif
