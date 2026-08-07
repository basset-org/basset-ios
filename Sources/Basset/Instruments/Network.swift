import BassetECS
import Foundation

#if canImport(Network)
import Network
#endif

/// No interception at all: NWPathMonitor is the API, and it reports every change
/// on its own. Which makes this the cheapest instrument in the domain and the one
/// that answers a question nothing else can — a request that failed on a train
/// failed because the interface moved, and no URLError says so.
final class PathTransitions: StreamingInstrument, @unchecked Sendable {
    #if canImport(Network)
    private struct Snapshot: Equatable {
        let interface: String
        let satisfied: Bool
        let expensive: Bool
        let constrained: Bool
        let reason: String?
    }

    private var monitor: NWPathMonitor?
    private let lock: NSLock = .init()
    private var last: Snapshot?
    #endif

    static let id: InstrumentID = .networkPathTransitions
    static let entity = Entity.ID.networkPath

    init() {}

    #if canImport(Network)
    private static func interface(of path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) {
            return "wifi"
        }
        if path.usesInterfaceType(.cellular) {
            return "cellular"
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return "wired"
        }
        if path.usesInterfaceType(.loopback) {
            return "loopback"
        }
        return "none"
    }

    /// localNetworkDenied is the only public tell that the user declined the
    /// local-network prompt, which otherwise presents as zero peers and no error
    /// at all.
    private static func reason(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: "notAvailable"
        case .cellularDenied: "cellularDenied"
        case .wifiDenied: "wifiDenied"
        case .localNetworkDenied: "localNetworkDenied"
        case .vpnInactive: "vpnInactive"
        @unknown default: "unknown"
        }
    }
    #endif

    func observe(_ context: Context) {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        // Every update, including the first: a capture needs to know what the
        // path was when it started, not only what it changed to.
        // A change, not a callback. NWPathMonitor reports every path change
        // it sees — a route, a DNS server, an interface index — and most of
        // those are invisible in what this emits. A walk produced 24 readings
        // for 3 transitions before this, which is eight times the reading cap
        // spent on saying the same thing.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            let now = Snapshot(
                interface: Self.interface(of: path),
                satisfied: path.status == .satisfied,
                expensive: path.isExpensive,
                constrained: path.isConstrained,
                reason: path.status == .satisfied
                    ? nil : Self.reason(path.unsatisfiedReason)
            )
            let changed = self.lock.withLock {
                guard now != self.last else {
                    return false
                }

                self.last = now
                return true
            }
            guard changed else {
                return
            }

            context.emit { out in
                out.put(.interfaceKind(now.interface))
                out.put(.pathSatisfied(now.satisfied))
                out.put(.expensiveInterface(now.expensive))
                out.put(.constrainedInterface(now.constrained))
                if let reason = now.reason {
                    out.put(.unsatisfiedReason(reason))
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: QueueLabel.networkPath))
        #endif
    }

    func stopObserving() {
        #if canImport(Network)
        monitor?.cancel()
        monitor = nil
        lock.withLock { last = nil }
        #endif
    }
}

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
    static let id: InstrumentID = .sessionConfiguration
    static let entity = Entity.ID.networkSession

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

final class TaskMetrics: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentID = .urlSessionTaskMetrics
    static let entity = Entity.ID.networkTask

    #if os(iOS)
    /// Every HTTP and WebSocket task-producing call on `URLSession`, by argument
    /// count, because the hook shape is decided by the arity.
    ///
    /// Stream tasks are the deliberate omission. `streamTaskWithHostName:port:`
    /// takes an object and an integer, a shape nothing here can hook, and a
    /// stream task carries no HTTP transaction to report — so the reading it
    /// would produce is a name and a failure with no phases under it.
    ///
    /// The completion-handler variants matter most: they are how most app
    /// traffic is written, and they bypass the delegate messages a task delegate
    /// would otherwise be the obvious home for. Within HTTP the list has to be
    /// exhaustive rather than representative — a request made through a variant
    /// that is missing produces no reading at all, and a capture silent about a
    /// file upload reads as an app that made no request.
    private static let oneObjectFactories = [
        "dataTaskWithRequest:",
        "dataTaskWithURL:",
        "downloadTaskWithRequest:",
        "downloadTaskWithURL:",
        "downloadTaskWithResumeData:",
        "uploadTaskWithStreamedRequest:",
        "webSocketTaskWithURL:",
        "webSocketTaskWithRequest:",
    ]

    private static let twoObjectFactories = [
        "dataTaskWithRequest:completionHandler:",
        "dataTaskWithURL:completionHandler:",
        "uploadTaskWithRequest:fromData:",
        "uploadTaskWithRequest:fromFile:",
        "downloadTaskWithRequest:completionHandler:",
        "downloadTaskWithURL:completionHandler:",
        "downloadTaskWithResumeData:completionHandler:",
        "webSocketTaskWithURL:protocols:",
    ]

    private static let threeObjectFactories = [
        "uploadTaskWithRequest:fromData:completionHandler:",
        "uploadTaskWithRequest:fromFile:completionHandler:",
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
        for name in threeObjectFactories {
            _ = hooks.swizzle.afterFactory(
                URLSession.self, Selector(name), takingThreeObjects: ()
            ) { receiver, _, _, _, made in
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

#if os(iOS)
import Foundation

/// A task delegate that records and forwards. Concrete rather than NSProxy: the
/// same delegate receives didReceive data: on every chunk, and forwardInvocation:
/// builds an NSInvocation per message.
///
/// Installed at task creation and dormant until an activation hands it a context,
/// which is why these are themselves registered — walking a registry of proxies is
/// how the runner reaches objects it created before any request existed.
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

/// Where a request's time actually went, from the eleven timestamps
/// `URLSessionTaskMetrics` carries and almost nobody reads.
///
/// A duration says a request took four seconds. That is not a finding — it is
/// the start of five different investigations. DNS taking four seconds is a
/// resolver problem, TLS taking four is a handshake or a certificate chain, and
/// four seconds between the request ending and the response starting is the
/// server thinking. Only the split tells them apart, and no app can obtain it
/// any other way.
///
/// Each phase is `nil` rather than zero when its timestamps are absent, which is
/// the ordinary case: a reused connection has no lookup, connect or handshake to
/// report, and reporting zeroes would say those phases were instantaneous when
/// in fact they did not happen.
struct TransactionPhases: Equatable {
    let dns: UInt64?
    let connect: UInt64?
    let tls: UInt64?
    /// Between the request finishing and the first byte of the response — the
    /// server's own time, and the only part of a slow request the app cannot fix.
    let server: UInt64?
    let response: UInt64?

    init(
        domainLookupStart: Date?, domainLookupEnd: Date?,
        connectStart: Date?, connectEnd: Date?,
        secureConnectionStart: Date?, secureConnectionEnd: Date?,
        requestEnd: Date?, responseStart: Date?, responseEnd: Date?
    ) {
        dns = Self.elapsed(from: domainLookupStart, to: domainLookupEnd)
        tls = Self.elapsed(from: secureConnectionStart, to: secureConnectionEnd)
        server = Self.elapsed(from: requestEnd, to: responseStart)
        self.response = Self.elapsed(from: responseStart, to: responseEnd)

        // The TLS handshake happens inside the connect window, so a connect that
        // reports the whole span double-counts the handshake against itself.
        // What is useful is the transport connect alone.
        let whole = Self.elapsed(from: connectStart, to: connectEnd)
        connect =
            switch (whole, tls) {
            case (let whole?, let tls?): whole > tls ? whole - tls : 0
            case (let whole?, nil): whole
            default: nil
            }
    }

    /// Timestamps that run backwards are refused rather than wrapped. These come
    /// from a framework, and an unsigned subtraction of a bad pair produces an
    /// eighteen-quintillion-nanosecond phase that reads as a finding.
    private static func elapsed(from start: Date?, to end: Date?) -> UInt64? {
        guard let start, let end else {
            return nil
        }

        let seconds = end.timeIntervalSince(start)
        guard seconds >= 0 else {
            return nil
        }

        return UInt64(seconds * 1000000000)
    }

    func write(into out: inout Readings) {
        if let dns {
            out.put(.dnsNanoseconds(dns))
        }
        if let connect {
            out.put(.connectNanoseconds(connect))
        }
        if let tls {
            out.put(.tlsNanoseconds(tls))
        }
        if let server {
            out.put(.serverNanoseconds(server))
        }
        if let response {
            out.put(.responseNanoseconds(response))
        }
    }
}

#if os(iOS)
extension TransactionPhases {
    init(_ transaction: URLSessionTaskTransactionMetrics) {
        self.init(
            domainLookupStart: transaction.domainLookupStartDate,
            domainLookupEnd: transaction.domainLookupEndDate,
            connectStart: transaction.connectStartDate,
            connectEnd: transaction.connectEndDate,
            secureConnectionStart: transaction.secureConnectionStartDate,
            secureConnectionEnd: transaction.secureConnectionEndDate,
            requestEnd: transaction.requestEndDate,
            responseStart: transaction.responseStartDate,
            responseEnd: transaction.responseEndDate
        )
    }
}

/// How the connection was secured, and over which interface it ran.
///
/// The TLS pair answers a question that otherwise needs a proxy to see: an app
/// pinned to a protocol version its server stopped accepting fails with a
/// generic error, and the negotiated version is the only thing that says so.
enum TransactionConnection {
    static func write(
        _ transaction: URLSessionTaskTransactionMetrics,
        into out: inout Readings
    ) {
        if let version = transaction.negotiatedTLSProtocolVersion {
            out.put(.tlsVersion(name(of: version)))
        }
        if let suite = transaction.negotiatedTLSCipherSuite {
            out.put(.tlsCipherSuite("0x" + String(
                suite.rawValue,
                radix: 16,
                uppercase: true
            )))
        }
        // Which interface actually carried this request, as opposed to which one
        // the path was satisfied by. `network.path.transitions` answers the
        // second; a request can be issued across a change of the first.
        out.put(.interfaceKind(transaction.isCellular ? "cellular" : "other"))
        if transaction.isExpensive {
            out.put(.expensiveInterface(true))
        }
        if transaction.isConstrained {
            out.put(.constrainedInterface(true))
        }
        // Which POP served the request. `remoteAddress` is the server's and is
        // safe; `localAddress` is the device's own and is never emitted.
        if let remote = transaction.remoteAddress {
            out.put(.remoteAddress(remote))
        }
        // A corporate or VPN proxy explains latency and handshake oddities the
        // app has no other way of seeing, and the app did not configure it.
        if transaction.isProxyConnection {
            out.put(.proxyConnection(true))
        }
        if transaction.isMultipath {
            out.put(.multipath(true))
        }
        out.put(.dnsProtocol(name(of: transaction.domainResolutionProtocol)))
    }

    /// Named rather than numbered. `0x0304` is TLS 1.3 to somebody who already
    /// knows, and the reading is for somebody who does not.
    static func name(of version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv10: "TLS 1.0"
        case .TLSv11: "TLS 1.1"
        case .TLSv12: "TLS 1.2"
        case .TLSv13: "TLS 1.3"
        case .DTLSv10: "DTLS 1.0"
        case .DTLSv12: "DTLS 1.2"
        @unknown default: "unrecognised(0x\(String(version.rawValue, radix: 16)))"
        }
    }

    private static func name(
        of resolution: URLSessionTaskMetrics.DomainResolutionProtocol
    ) -> String {
        switch resolution {
        case .unknown: "unknown"
        case .udp: "udp"
        case .tcp: "tcp"
        case .tls: "tls"
        case .https: "https"
        @unknown default: "unrecognised(\(resolution.rawValue))"
        }
    }
}
#endif

/// The App Transport Security posture this build shipped with.
///
/// ATS is decided at build time and enforced at run time, and when it refuses a
/// load the app gets a generic `URLError` that looks like any other failure. The
/// developer's own machine usually cannot reproduce it: a debug build talking to
/// a local server over http is exempt, and the shipped one is not. So a URL that
/// works everywhere except in production has an answer that lives in the
/// `Info.plist` and nowhere else.
///
/// Free, like `permissions.status`'s usage descriptions and for the same reason:
/// the build already carries it, and reading it prompts nothing and costs
/// nothing.
final class TransportSecurity: SnapshotInstrument {
    /// The blanket exemptions, each of which widens what the whole app may load.
    /// Named rather than reported as raw keys, because the key is what a reader
    /// would have to look up and the name is what they wanted.
    private enum Relaxation: String, CaseIterable {
        case webContent = "NSAllowsArbitraryLoadsInWebContent"
        case media = "NSAllowsArbitraryLoadsForMedia"
        case localNetworking = "NSAllowsLocalNetworking"

        var description: String {
            switch self {
            case .webContent: "arbitrary loads allowed in web content"
            case .media: "arbitrary loads allowed for media"
            case .localNetworking: "local networking allowed"
            }
        }
    }

    static let id: InstrumentID = .transportSecurity
    static let entity = Entity.ID.transportSecurity

    private static let key = "NSAppTransportSecurity"

    init() {}

    static func write(_ settings: [String: Any]?, into out: inout Readings) {
        guard let settings else {
            // No dictionary is ATS at its defaults, which is a posture rather
            // than an absence: every load must be https with TLS 1.2 or better.
            out.put(.arbitraryLoadsAllowed(false))
            out.put(.mechanismStatus("no NSAppTransportSecurity key; defaults apply"))
            return
        }

        out
            .put(.arbitraryLoadsAllowed(settings["NSAllowsArbitraryLoads"] as? Bool ??
                    false))
        for relaxation in Relaxation.allCases
            where settings[relaxation.rawValue] as? Bool == true
        {
            out.put(.detail(relaxation.description))
        }

        let domains = settings["NSExceptionDomains"] as? [String: Any] ?? [:]
        out.put(.occurrenceCount(UInt64(domains.count)))

        // Sorted, so two captures of one build list the exceptions in one order.
        for name in domains.keys.sorted() {
            let exception = domains[name] as? [String: Any] ?? [:]
            out.also(Self.entity) { sibling in
                sibling.put(.exceptionDomain(name))
                sibling.put(
                    .insecureLoadsAllowed(
                        exception["NSExceptionAllowsInsecureHTTPLoads"] as? Bool ?? false
                    )
                )
                if let minimum = exception["NSExceptionMinimumTLSVersion"] as? String {
                    sibling.put(.minimumTLSVersion(minimum))
                }
            }
        }
    }

    func reading(_ out: inout Readings) {
        Self.write(
            Bundle.main.object(forInfoDictionaryKey: Self.key) as? [String: Any],
            into: &out
        )
    }
}
