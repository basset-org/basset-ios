import BassetECS
import Foundation

#if canImport(Network)
import Network
#endif

/// No interception — `NWPathMonitor` already reports every change on its own.
final class PathTransitions: Streamable, PlainInstrument, @unchecked Sendable {
    #if canImport(Network)
    private struct Snapshot: Equatable {
        let interface: String
        let satisfied: Bool
        let expensive: Bool
        let constrained: Bool
        let reason: String?
    }

    private var monitor: NWPathMonitor?
    private let last: Mutex<Snapshot?> = .init(nil)
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

    /// `localNetworkDenied` is the only public tell for a declined local-network prompt.
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
        // Deduplicated: a device walk produced 24 raw updates for 3 actual transitions.
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
            let changed = self.last.withLock { last in
                guard now != last else {
                    return false
                }

                last = now
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
        last.withLock { $0 = nil }
        #endif
    }
}

/// What a `URLSession` was configured to allow, described off `taskMetrics`'s own hook.
final class SessionConfiguration: Streamable, PlainInstrument {
    static let id: InstrumentID = .sessionConfiguration
    static let entity = Entity.ID.networkSession

    #if os(iOS)
    static let untouchedTLSFloor = URLSessionConfiguration.ephemeral
        .tlsMinimumSupportedProtocolVersion
    #endif

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
            // Compares against a fresh config — the TLS floor moved across OS releases.
            if configuration.tlsMinimumSupportedProtocolVersion != untouchedTLSFloor {
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
        context.follow(URLSession.self) { session, instance in
            guard !IgnoredSessions.contains(session) else {
                return
            }

            Self.describe(session, instance: instance, into: context)
        }
        #endif
    }

    func stopObserving() {}
}

final class TaskMetrics: Streamable, PlainInstrument, LoadTimeInstall {
    static let id: InstrumentID = .urlSessionTaskMetrics
    static let entity = Entity.ID.networkTask

    #if os(iOS)
    /// Stream tasks omitted — unhookable factory shape, no HTTP transaction to report.
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

    /// `#selector`, not a string — the ObjC name adds `Metrics` unlike Swift's.
    static let didFinishCollecting = #selector(
        URLSessionTaskDelegate.urlSession(_:task:didFinishCollecting:)
    )
    static let didCompleteWithError = #selector(
        URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)
    )
    private static let setDelegate: Selector = .init("setDelegate:")

    private static let hooksTaskClasses: Mutex<Set<ObjectIdentifier>> = .init([])

    /// One key for both delegate seams — session and task delegates commonly share a class.
    static func delegateClasses(_ registries: Registries) -> DelegateClasses {
        registries.delegates(ObjectIdentifier(URLSession.self))
    }

    /// Tracks session creation — Swift's awaited `data(from:)` bypasses every task factory.
    static func trackSession(
        _ made: AnyObject?,
        _ delegate: AnyObject?,
        _ hooks: HookTable
    ) {
        guard let session = made as? URLSession,
              !IgnoredSessions.contains(session)
        else {
            return
        }

        // Before the registry — the uplink session isn't yet marked as basset's.
        if let delegate, isBassetsOwn(delegate) {
            return
        }

        hooks.registries.registry(URLSession.self).add(session)
        guard let delegate else {
            return
        }

        delegateClasses(hooks.registries).add(Self.publicClass(of: delegate))
    }

    /// Refused by class, not session — the class is knowable before construction finishes.
    private static func isBassetsOwn(_ delegate: AnyObject) -> Bool {
        type(of: delegate) == RedirectRefusal.self
    }

    /// `classForCoder`, not the isa: KVO's dynamic subclass melts away with its observer.
    private static func publicClass(of object: AnyObject) -> AnyClass {
        (object as? NSObject)?.classForCoder ?? type(of: object)
    }

    /// Nothing substituted — only the delegate's class is taken, enough to wrap the callback.
    private static func trackTask(
        _ made: AnyObject?,
        of receiver: AnyObject,
        _ hooks: HookTable
    ) {
        guard made is URLSessionTask,
              let session = receiver as? URLSession,
              !IgnoredSessions.contains(session)
        else {
            return
        }

        hooks.registries.registry(URLSession.self).add(session)

        let classes = delegateClasses(hooks.registries)
        if let delegate = session.delegate, !isBassetsOwn(delegate) {
            classes.add(publicClass(of: delegate))
        }
        guard let task = made else {
            return
        }

        // Claimed before installing — two racing threads can't both proceed uninstalled.
        let concrete: AnyClass = publicClass(of: task)
        hooksTaskClasses.withLock { hooked in
            guard hooked.insert(ObjectIdentifier(concrete)).inserted else {
                return
            }

            _ = hooks.swizzle.after(concrete, setDelegate) { _, delegate in
                guard let delegate, !isBassetsOwn(delegate) else {
                    return
                }

                classes.add(publicClass(of: delegate))
            }
        }
    }
    #endif

    /// The follower tokens this activation took out, with the registry that
    /// issued them: dropping a token without withdrawing it leaves a closure
    /// holding a torn-down context, which the next delegate class would call.
    private let followed: Mutex<[(DelegateClasses, Int)]> = .init([])

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        // Session creation first — the only chokepoint every calling convention shares.
        _ = hooks.swizzle.afterFactory(
            URLSession.self,
            Selector(("sessionWithConfiguration:delegate:delegateQueue:")),
            takingThreeObjects: (),
            kind: .type
        ) { _, _, delegate, _, made in
            Self.trackSession(made, delegate, hooks)
        }
        _ = hooks.swizzle.afterFactory(
            URLSession.self,
            Selector(("sessionWithConfiguration:")),
            takingOneObject: (),
            kind: .type
        ) { _, _, made in
            Self.trackSession(made, nil, hooks)
        }

        // ObjC selector strings — dataTask(with:) overloads two distinct selectors.
        for name in oneObjectFactories {
            _ = hooks.swizzle.afterFactory(
                URLSession.self, Selector(name), takingOneObject: ()
            ) { receiver, _, made in
                Self.trackTask(made, of: receiver, hooks)
            }
        }
        for name in twoObjectFactories {
            _ = hooks.swizzle.afterFactory(
                URLSession.self, Selector(name), takingTwoObjects: ()
            ) { receiver, _, _, made in
                Self.trackTask(made, of: receiver, hooks)
            }
        }
        for name in threeObjectFactories {
            _ = hooks.swizzle.afterFactory(
                URLSession.self, Selector(name), takingThreeObjects: ()
            ) { receiver, _, _, _, made in
                Self.trackTask(made, of: receiver, hooks)
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
            // Without this, a four-second task from 4 redirects reads as one slow request.
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

    /// A `URLError` code separates "the server said no" from "the interface moved".
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
        // An infinite interval would trap the conversion; nothing real runs a billion seconds.
        guard seconds > 0, seconds < 1000000000 else {
            return 0
        }

        return UInt64(seconds * 1000000000)
    }
    #endif

    func observe(_ context: Context) {
        #if os(iOS)
        let classes = Self.delegateClasses(context.registries)
        let token = classes.attachAndFollow { [weak self] delegateClass in
            self?.watch(delegateClass, context)
        }
        followed.withLock { $0.append((classes, token)) }
        #endif
    }

    func stopObserving() {
        #if os(iOS)
        followed.withLock { taken in
            for (classes, token) in taken {
                classes.stopFollowing(token)
            }
            taken.removeAll()
        }
        #endif
    }

    #if os(iOS)
    /// Wrapped where the app wrote it, defined where it did not. Most delegates
    /// never implement `didFinishCollecting:`, and wrapping only what exists
    /// would report a request's phases for the few apps that already collect
    /// them and nothing for everybody else.
    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        let collecting = context.swizzle.afterOrDefine(
            delegateClass, Self.didFinishCollecting, takingThreeObjects: ()
        ) { delegate, session, task, metrics in
            guard let session = session as? URLSession,
                  let task = task as? URLSessionTask,
                  let metrics = metrics as? URLSessionTaskMetrics,
                  !IgnoredSessions.contains(session),
                  let instance = context.registries
                  .registry(URLSession.self)
                  .instance(of: session)
            else {
                return
            }

            Self.emit(
                task,
                metrics,
                Self.arrival(at: delegate, of: task),
                instance: instance,
                into: context
            )
        }

        let completing = context.swizzle.afterOrDefine(
            delegateClass, Self.didCompleteWithError, takingThreeObjects: ()
        ) { _, session, task, failure in
            guard let session = session as? URLSession,
                  let task = task as? URLSessionTask,
                  let failure = failure as? NSError,
                  !IgnoredSessions.contains(session),
                  let instance = context.registries
                  .registry(URLSession.self)
                  .instance(of: session)
            else {
                return
            }

            Self.emit(task, failure, instance: instance, into: context)
        }

        // Which delegate class was reached and what happened there. A class the
        // app assigned but the hook refused is the difference between an app
        // that made no requests and an instrument that saw none, and nothing
        // else in the reading tells them apart.
        // `detail` is left alone: on every other reading here it names which of
        // the two delegates a callback landed on, and a status carrying one
        // would read as a request that had been made.
        context.emit { out in
            out.put(
                .mechanismStatus(
                    "\(NSStringFromClass(delegateClass)): "
                        + "didFinishCollecting \(collecting), "
                        + "didCompleteWithError \(completing)"
                )
            )
        }
    }

    /// Which of the two delegates the callback landed on. A task delegate takes
    /// precedence over the session's for task-level messages, so an app that
    /// sets one per request is described by a different object than an app that
    /// sets one per session — and only the reading says which.
    private static func arrival(at delegate: AnyObject, of task: URLSessionTask) -> String {
        guard let owned = task.delegate else {
            return "sessionDelegate"
        }

        return owned === delegate ? "taskDelegate" : "sessionDelegate"
    }
    #endif
}

/// Splits a request's duration into DNS/connect/TLS/server/response phases.
struct TransactionPhases: Equatable {
    let dns: UInt64?
    let connect: UInt64?
    let tls: UInt64?
    /// Request end to first response byte — the part of a slow request the app can't fix.
    let server: UInt64?
    let response: UInt64?

    init(
        domainLookupStart: Date?, domainLookupEnd: Date?,
        connectStart: Date?, connectEnd: Date?,
        secureConnectionStart: Date?, secureConnectionEnd: Date?,
        requestEnd: Date?, responseStart: Date?, responseEnd: Date?
    ) {
        // nil rather than zero — a reused connection has nothing to report for these phases.
        dns = Self.elapsed(from: domainLookupStart, to: domainLookupEnd)
        tls = Self.elapsed(from: secureConnectionStart, to: secureConnectionEnd)
        server = Self.elapsed(from: requestEnd, to: responseStart)
        self.response = Self.elapsed(from: responseStart, to: responseEnd)

        // Handshake time is inside the connect window — subtracted to isolate transport.
        let whole = Self.elapsed(from: connectStart, to: connectEnd)
        connect =
            switch (whole, tls) {
            case (let whole?, let tls?): whole > tls ? whole - tls : 0
            case (let whole?, nil): whole
            default: nil
            }
    }

    /// Backwards timestamps refused, not wrapped — unsigned subtraction would read as real.
    private static func elapsed(from start: Date?, to end: Date?) -> UInt64? {
        guard let start, let end else {
            return nil
        }

        let seconds = end.timeIntervalSince(start)
        // The upper bound refuses an infinite pair, which would trap the conversion.
        guard seconds >= 0, seconds < 1000000000 else {
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
        // The interface that carried this request, not the one the path was satisfied by.
        out.put(.interfaceKind(transaction.isCellular ? "cellular" : "other"))
        if transaction.isExpensive {
            out.put(.expensiveInterface(true))
        }
        if transaction.isConstrained {
            out.put(.constrainedInterface(true))
        }
        // `remoteAddress` is safe; `localAddress` (the device's) is never emitted.
        if let remote = transaction.remoteAddress {
            out.put(.remoteAddress(remote))
        }
        if transaction.isProxyConnection {
            out.put(.proxyConnection(true))
        }
        if transaction.isMultipath {
            out.put(.multipath(true))
        }
        out.put(.dnsProtocol(name(of: transaction.domainResolutionProtocol)))
    }

    /// Named, not numbered — `0x0304` means nothing without already knowing TLS 1.3.
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

/// This build's ATS posture — debug exemptions don't apply in production.
final class TransportSecurity: Snapshotable, PlainInstrument {
    /// Named rather than reported as raw `Info.plist` keys.
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
            // No dictionary means ATS defaults, not an absence — https with TLS 1.2+.
            out.put(.arbitraryLoadsAllowed(false))
            out.put(.mechanismStatus("no NSAppTransportSecurity key; defaults apply"))
            out.putStructure(id: EntityIdentity.next(), parent: 0, level: 0)
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

        let root = EntityIdentity.next()
        out.putStructure(id: root, parent: 0, level: 0)

        // Sorted so two captures of one build list exceptions in the same order.
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
                sibling.putStructure(id: EntityIdentity.next(), parent: root, level: 1)
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
