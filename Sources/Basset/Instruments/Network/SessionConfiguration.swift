import BassetECS
import Foundation

/// What the app's `URLSession` was configured to allow, which no request outcome
/// reveals.
///
/// The "works on my machine" instrument. A session with `allowsCellularAccess`
/// off fails every request for one user and succeeds for everyone on wifi, and
/// the failures look identical to a server being down. A resource timeout of a
/// week produces requests that never fail and never finish. `waitsForConnectivity`
/// turns a hung request into a request that is patiently waiting, which is a
/// different bug with the same symptom. None of it is inferable from what the
/// requests did — only from what they were permitted to do.
///
/// **Installs no chokepoint of its own.** `network.urlSession.taskMetrics`
/// already proxies task creation and its proxies hold the session they were made
/// for, so this rides the same registry. Two instruments, one hook, and the
/// configuration is described the first time a session makes a task rather than
/// on a timer.
final class SessionConfiguration: StreamingInstrument {
    static let id: InstrumentWireID = .sessionConfiguration
    static let entity = Entity.WireID.networkSession

    private let lock: NSLock = .init()
    private var described: Set<UInt32> = []

    init() {}

    #if os(iOS)
    private static func describe(
        _ session: URLSession,
        instance: UInt32,
        into context: Context
    ) {
        let configuration = session.configuration
        context.emit { out in
            out.put(.instanceId(instance))
            out
                .put(.requestTimeoutSeconds(Float(configuration
                        .timeoutIntervalForRequest)))
            out
                .put(.resourceTimeoutSeconds(Float(configuration
                        .timeoutIntervalForResource)))
            out.put(.allowsCellular(configuration.allowsCellularAccess))
            out.put(.allowsExpensive(configuration.allowsExpensiveNetworkAccess))
            out.put(.allowsConstrained(configuration.allowsConstrainedNetworkAccess))
            out.put(.waitsForConnectivity(configuration.waitsForConnectivity))
            out.put(
                .maximumConnectionsPerHost(
                    UInt32(clamping: configuration.httpMaximumConnectionsPerHost)
                )
            )
            out.put(.cachePolicy(name(of: configuration.requestCachePolicy)))
            out.put(.sessionClass(String(describing: type(of: session))))
            if configuration.multipathServiceType != .none {
                out.put(.multipath(true))
            }
            // Only when the app raised it. The default floor is TLS 1.2 and
            // saying so on every session buries the app that moved it.
            if configuration.tlsMinimumSupportedProtocolVersion != .TLSv12 {
                out
                    .put(.tlsVersion(TransactionConnection
                            .name(of: configuration.tlsMinimumSupportedProtocolVersion)))
            }
        }
    }

    private static func name(of policy: NSURLRequest.CachePolicy) -> String {
        switch policy {
        case .useProtocolCachePolicy: "protocolDefault"
        case .reloadIgnoringLocalCacheData: "ignoreLocalCache"
        case .reloadIgnoringLocalAndRemoteCacheData: "ignoreAllCaches"
        case .returnCacheDataElseLoad: "cacheElseLoad"
        case .returnCacheDataDontLoad: "cacheOnly"
        case .reloadRevalidatingCacheData: "revalidate"
        @unknown default: "unrecognised(\(policy.rawValue))"
        }
    }
    #endif

    func observe(_ context: Context) {
        #if os(iOS)
        context.follow(TaskMetricsDelegate.self) { [weak self] proxy, instance in
            guard let self, let session = proxy.session else {
                return
            }

            // A session makes many tasks and so is seen many times. Its
            // configuration is fixed at creation, so the second reading would be
            // the first one repeated.
            let isNew = self.lock.withLock { self.described.insert(instance).inserted }
            guard isNew else {
                return
            }

            Self.describe(session, instance: instance, into: context)
        }
        #endif
    }

    func stopObserving() {
        lock.withLock { described.removeAll() }
    }
}
