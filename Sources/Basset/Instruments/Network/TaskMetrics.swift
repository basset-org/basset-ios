import BassetECS
import Foundation

final class TaskMetrics: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .urlSessionTaskMetrics
    static let entity = Entity.WireID.networkTask

    #if os(iOS)
    /// Every task in the catalog's reach comes from one of these. The
    /// completion-handler variants are the ones that matter most: they are how
    /// most app traffic is written, and they bypass the delegate messages a
    /// task delegate would otherwise be the obvious home for.
    private static let oneObjectFactories = [
        "dataTaskWithRequest:",
        "dataTaskWithURL:",
        "downloadTaskWithRequest:",
        "downloadTaskWithURL:",
    ]

    private static let twoObjectFactories = [
        "dataTaskWithRequest:completionHandler:",
        "dataTaskWithURL:completionHandler:",
        "uploadTaskWithRequest:fromData:",
        "downloadTaskWithRequest:completionHandler:",
    ]

    private static func attach(
        to made: AnyObject?,
        of receiver: AnyObject,
        _ hooks: HookTable
    ) {
        guard let task = made as? URLSessionTask,
              let session = receiver as? URLSession,
              !IgnoredSessions.contains(session)
        else {
            return
        }

        let proxy = TaskMetricsDelegate(
            session: session,
            existing: task.delegate as? URLSessionTaskDelegate
        )
        task.delegate = proxy
        hooks.registries.registry(TaskMetricsDelegate.self).add(proxy)
    }
    #endif

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        // The factory is the chokepoint. A task's delegate is settable, so
        // nothing about the app's call is altered — the task is handed one it
        // would otherwise not have had, and it forwards everything.
        //
        // basset's own uplink is excluded by the runtime, not by a header
        // sentinel: HTTP2Channel builds its session through the runtime, which
        // records it, and a recorded session's tasks are left alone.
        // ObjC selector names rather than #selector: dataTask(with:) is
        // overloaded in Swift over URL and URLRequest, which are two distinct
        // ObjC selectors, and the arity has to match the shape exactly.
        for name in oneObjectFactories {
            _ = hooks.swizzle.afterFactory(
                URLSession.self, Selector(name), takingOneObject: ()
            ) { receiver, _, made in
                Self.attach(to: made, of: receiver, hooks)
            }
        }
        for name in twoObjectFactories {
            _ = hooks.swizzle.afterFactory(
                URLSession.self, Selector(name), takingTwoObjects: ()
            ) { receiver, _, _, made in
                Self.attach(to: made, of: receiver, hooks)
            }
        }
        #endif
    }

    #if os(iOS)
    private static func emit(
        _ task: URLSessionTask,
        _ metrics: URLSessionTaskMetrics,
        _ path: String,
        instance: UInt32,
        into context: Context
    ) {
        guard let transaction = metrics.transactionMetrics.last else {
            return
        }

        context.emit { out in
            out.put(.instanceId(instance))
            out.put(.detail(path))
            out.put(.requestURL(Redaction.url(task.originalRequest?.url)))
            out.put(.totalNanoseconds(Self.nanoseconds(metrics.taskInterval.duration)))

            if let response = transaction.response as? HTTPURLResponse {
                out.put(.httpStatusCode(Int32(response.statusCode)))
            }
            if let negotiated = transaction.networkProtocolName {
                out.put(.negotiatedProtocol(negotiated))
            }
            out.put(.connectionReused(transaction.isReusedConnection))
            // A redirect or a retry is its own transaction, and the duration
            // above covers all of them. Without the count a four-second task
            // reads as one slow request when it was four quick ones.
            if metrics.transactionMetrics.count > 1 {
                out.put(.transactionCount(UInt32(metrics.transactionMetrics.count)))
            }
            TransactionPhases(transaction).write(into: &out)
            TransactionConnection.write(transaction, into: &out)
            if transaction.countOfRequestBodyBytesSent > 0 {
                out.put(.bytesSentCount(UInt64(transaction.countOfRequestBodyBytesSent)))
            }
            if transaction.countOfResponseBodyBytesReceived > 0 {
                out.put(
                    .bytesReceivedCount(
                        UInt64(transaction.countOfResponseBodyBytesReceived)
                    )
                )
            }
        }
    }

    /// Why the request ended, when it ended badly. A URLError code is the
    /// difference between "the server said no" and "the interface moved", and
    /// only one of those is the app's problem.
    private static func emit(
        _ task: URLSessionTask,
        _ error: Error,
        instance: UInt32,
        into context: Context
    ) {
        let failure = error as NSError
        context.emit { out in
            out.put(.instanceId(instance))
            out.put(.requestURL(Redaction.url(task.originalRequest?.url)))
            out.put(.errorDomain(failure.domain))
            out.put(.errorCode(Int32(truncatingIfNeeded: failure.code)))
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        seconds > 0 ? UInt64(seconds * 1000000000) : 0
    }
    #endif

    func observe(_ context: Context) {
        #if os(iOS)
        context.follow(TaskMetricsDelegate.self) { proxy, instance in
            proxy.report(
                into: { task, metrics, path in
                    Self.emit(task, metrics, path, instance: instance, into: context)
                },
                failures: { task, error in
                    Self.emit(task, error, instance: instance, into: context)
                }
            )
        }
        #endif
    }

    func stopObserving() {}
}
