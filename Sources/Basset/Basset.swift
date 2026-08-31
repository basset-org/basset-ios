@_exported import BassetEntityComponent
import Foundation
import Network

public struct Config: Sendable {
    public var apiKey: String
    public var control: URL
    public var quicPort: UInt16
    public var http2Port: UInt16
    public var ingestDomain: String?

    /// Ports are defaults: the control plane names the ingest host, not its port.
    public init(
        apiKey: String,
        control: URL = URL(string: "https://ctrl.basset.dev")!,
        quicPort: UInt16 = 30943,
        http2Port: UInt16 = 30944,
        ingestDomain: String? = nil
    ) {
        self.apiKey = apiKey
        self.control = control
        self.quicPort = quicPort
        self.http2Port = http2Port
        self.ingestDomain = ingestDomain
    }
}

public enum Basset {
    /// Held across `start` so a concurrent `identify` cannot race `startFromDisk`.
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var loop: DeviceLoop?

    public static func start(apiKey: String) {
        start(Config(apiKey: apiKey))
    }

    public static func start(_ config: Config) {
        // Taken now, on the main thread, before a later request finds it unresponsive.
        MainThreadPort.capture()

        // Captured before any request can arrive, so activation reads real app state.
        ApplicationPresence.capture()

        lock.lock()
        guard loop == nil else {
            lock.unlock()
            return
        }

        let started = DeviceLoop(config: config)
        loop = started

        // Started under the lock: startFromDisk restores what the last run persisted,
        // and an attached document converging first would be replaced by it.
        started.start()
        lock.unlock()

        // Outside the lock: replaying reaches converge, which takes it again, and it
        // is not reentrant — holding it here deadlocks the thread an app launches on.
        #if DEBUG
        AttachedBridge.applyWhatArrivedBeforeTheLoop()
        #endif
    }

    /// Associates this device with one of your users, so a request can target them by id.
    public static func identify(userId: String?) {
        lock.lock()
        let running = loop
        lock.unlock()
        running?.identify(userId: userId)
    }

    /// Excludes a session's traffic from network instruments — a request already made still counts.
    public static func ignoreUrlSession(_ session: URLSession) {
        IgnoredSessions.add(session)
    }

    /// What the SDK is doing, for an app that wants to show it. Read-only. Nil until `start`.
    public static func currentState() -> DeviceState? {
        lock.lock()
        let running = loop
        lock.unlock()
        return running?.currentState()
    }

    /// Empty before `start` — nothing has installed its load-time hooks yet to probe.
    static func defaultRelevantInstruments() -> Set<InstrumentID> {
        lock.lock()
        let running = loop
        lock.unlock()
        return running?.defaultRelevantInstruments ?? []
    }

    #if DEBUG
    /// Undoes `start`, which is otherwise permanent for the life of the process. A
    /// test that starts the SDK and cannot stop it leaves every later test in that
    /// process running against a started one.
    static func stopForTesting() {
        lock.lock()
        let running = loop
        loop = nil
        lock.unlock()
        running?.stop()
    }

    static func forgetAttachedTransports() {
        lock.lock()
        let running = loop
        lock.unlock()
        running?.forgetTransports()
    }

    @discardableResult
    static func converge(to state: DesiredState) -> Bool {
        lock.lock()
        let running = loop
        lock.unlock()
        guard let running else {
            return false
        }

        running.converge(to: state)
        return true
    }
    #endif
}

/// Launch, then poll, holding between calls — everything the device asks the control plane.
final class DeviceLoop: @unchecked Sendable {
    private struct State {
        var userId: String?
        var lastCtrlResponse: CtrlResponse?
        var ingestEndpoint: String?
        var stateVersion: String?
    }

    private let config: Config
    private let control: LazyControlClient
    private let identity: DeviceIdentity
    private let runner: InstrumentRunner
    private let guarded: Mutex<State> = .init(State())
    private var following: Task<Void, Never>?

    var defaultRelevantInstruments: Set<InstrumentID> {
        runner.defaultRelevantInstruments
    }

    init(config: Config) {
        self.config = config
        self.identity = DeviceIdentity.current()
        let endpoint = config.control
        let apiKey = config.apiKey
        self.control = LazyControlClient {
            ControlClient(endpoint: endpoint, apiKey: apiKey)
        }
        self.runner = InstrumentRunner(opener: IngestTransports(config: config))
    }

    /// First rejection retries immediately in case it was transient; backs off after.
    static func rejectionDelay(afterConsecutive rejections: Int) -> Duration? {
        guard rejections > 0 else {
            return nil
        }

        return min(.seconds(1 << min(rejections - 1, 6)), .seconds(60))
    }

    func start() {
        // Before the network, so an at_launch instrument isn't measuring something already over.
        runner.startFromDisk()

        following = Task.detached(priority: .utility) { [self] in
            await follow()
        }
    }

    #if DEBUG
    func stop() {
        following?.cancel()
        following = nil
        runner.expire(at: .distantFuture)
    }

    func forgetTransports() {
        runner.forgetTransports()
    }

    func converge(to state: DesiredState) {
        guarded.withLock { $0.ingestEndpoint = state.ingestEndpoint }
        runner.converge(to: state.requests, ingestEndpoint: state.ingestEndpoint)
    }
    #endif

    /// No forced refresh here — the loop's next poll reads userId fresh on its own.
    func identify(userId: String?) {
        guarded.withLock { $0.userId = userId }
    }

    func currentState() -> DeviceState {
        let (user, answer) = guarded.withLock { ($0.userId, $0.lastCtrlResponse) }

        return DeviceState(
            deviceId: identity.deviceId,
            model: identity.model,
            os: identity.os,
            appVersion: identity.appVersion,
            bundleId: identity.bundleId,
            buildConfiguration: identity.buildConfiguration,
            deviceKind: identity.deviceKind,
            control: config.control,
            userId: user,
            lastCtrlResponse: answer,
            requests: runner.requestStates(),
            activeInstruments: runner.activeInstrumentNames()
        )
    }

    private func poll() async throws {
        let (user, version) = guarded.withLock { ($0.userId, $0.stateVersion) }

        let response: DesiredState
        do {
            response = try await control.client().requests(
                identity,
                userId: user,
                stateVersion: version
            )
        } catch {
            record(outcome(for: error))
            throw error
        }

        record(.accepted(requestCount: response.requests.count))

        // Recorded even while attached: skipping it leaves the version stale, and the
        // control plane then answers every poll at once rather than holding one.
        guarded.withLock {
            $0.ingestEndpoint = response.ingestEndpoint
            $0.stateVersion = response.stateVersion
        }

        // A machine on this desk owns what runs while it is attached, and the check
        // has to be taken with the convergence or an attachment landing between the
        // two lets this response overwrite what that machine just asked for.
        #if DEBUG
        AttachedBridge.whileNothingIsAttached {
            runner.converge(to: response.requests, ingestEndpoint: response.ingestEndpoint)
        }
        #else
        runner.converge(to: response.requests, ingestEndpoint: response.ingestEndpoint)
        #endif
    }

    private func record(_ outcome: CtrlResponse.Outcome) {
        guarded.withLock {
            $0.lastCtrlResponse = CtrlResponse(outcome: outcome, at: Date())
        }
    }

    private func outcome(for error: Error) -> CtrlResponse.Outcome {
        switch error as? ControlError {
        case .unauthorized:
            .unauthorized
        case .refused(let status):
            .refused(status: status)
        case .notHTTP:
            .unreachable("the answer was not HTTP")
        case .oversized(let bytes):
            .unreachable("the answer was refused at \(bytes) bytes")
        case .insecureEndpoint:
            .unreachable("the control endpoint is not https")
        case .none:
            .unreachable(error.localizedDescription)
        }
    }

    private func follow() async {
        var backoff = Duration.seconds(1)
        var rejections = 0

        while !Task.isCancelled {
            do {
                try await poll()
                rejections = 0
                backoff = .seconds(1)
            } catch ControlError.unauthorized {
                if let delay = Self.rejectionDelay(afterConsecutive: rejections) {
                    try? await Task.sleep(for: delay)
                }

                rejections += 1
                continue
            } catch {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }
}

/// One stream per request, each opened with that request's own token — ingest routes on it.
struct IngestTransports: TransportOpener {
    private static let defaultControl = "https://ctrl.basset.dev"

    let config: Config

    private var ingestDomain: String? {
        if let configured = config.ingestDomain {
            return configured
        }
        return config.control.absoluteString == Self.defaultControl ? "basset.dev" : nil
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    func hostname(_ candidate: String) -> String? {
        guard let controlHost = config.control.host else {
            return nil
        }
        guard !Self.isIPLiteral(controlHost) else {
            return candidate.lowercased() == controlHost.lowercased() ? candidate : nil
        }
        guard !candidate.isEmpty, candidate.count <= 253 else {
            return nil
        }
        guard candidate.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }) else {
            return nil
        }

        let candidateLower = candidate.lowercased()
        guard let domain = ingestDomain?.lowercased() else {
            return candidateLower == controlHost.lowercased() ? candidate : nil
        }

        return candidateLower == domain || candidateLower.hasSuffix(".\(domain)") ? candidate : nil
    }

    func open(request: BassetRequest, ingestEndpoint: String) -> Transport? {
        #if DEBUG
        // An attached machine connected to us; readings go back down that socket rather
        // than out to an ingest host this build may not even be able to reach.
        if let channel = AttachedBridge.channel {
            return AttachedTransport(channel)
        }
        #endif

        guard
            let host = hostname(ingestEndpoint),
            let token = request.requestToken,
            let http2 =
            URL(string: "https://\(authority(for: host)):\(config.http2Port)/frames")
        else {
            return nil
        }

        // A closure, not an instance: a failed NWConnection can't restart, so retry rebuilds it.
        let quicPort = config.quicPort
        let transport = FailoverTransport(
            primary: {
                QUICChannel(
                    host: host,
                    port: quicPort,
                    token: token,
                    queue: DispatchQueue(label: QueueLabel
                        .quic(requestId: request.requestId))
                )
            },
            fallback: HTTP2Channel(endpoint: http2, token: token, requestId: request.requestId)
        )
        transport.start()
        return transport
    }

    private func authority(for host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}
