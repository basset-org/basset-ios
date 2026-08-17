@_exported import BassetECS
import Foundation

public struct Config: Sendable {
    public var apiKey: String
    public var control: URL
    public var quicPort: UInt16
    public var http2Port: UInt16

    /// Ports are defaults: the control plane names the ingest host, not its port.
    public init(
        apiKey: String,
        control: URL = URL(string: "https://ctrl.basset.dev")!,
        quicPort: UInt16 = 30943,
        http2Port: UInt16 = 30944
    ) {
        self.apiKey = apiKey
        self.control = control
        self.quicPort = quicPort
        self.http2Port = http2Port
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
        defer { lock.unlock() }
        guard loop == nil else {
            return
        }

        let started = DeviceLoop(config: config)
        loop = started
        started.start()
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
}

/// Launch, then poll, holding between calls — everything the device asks the control plane.
final class DeviceLoop: @unchecked Sendable {
    private struct State {
        var userId: String?
        var lastCtrlResponse: CtrlResponse?
        var ingestEndpoint: String?
    }

    private let config: Config
    private let control: LazyControlClient
    private let identity: DeviceIdentity
    private let runner: InstrumentRunner
    private let guarded: Mutex<State> = .init(State())
    private var following: Task<Void, Never>?

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

    func identify(userId: String?) {
        guarded.withLock { $0.userId = userId }

        Task.detached(priority: .utility) { [self] in
            try? await poll()
        }
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
        let user = guarded.withLock { $0.userId }

        let response: DesiredState
        do {
            response = try await control.client().requests(identity, userId: user)
        } catch {
            record(outcome(for: error))
            throw error
        }

        record(.accepted(requestCount: response.requests.count))
        guarded.withLock { $0.ingestEndpoint = response.ingestEndpoint }
        runner.converge(to: response.requests, ingestEndpoint: response.ingestEndpoint)
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
    let config: Config

    /// Rejects anything that isn't a bare hostname, so a malformed endpoint opens no stream.
    private static func hostname(_ candidate: String) -> String? {
        guard !candidate.isEmpty, candidate.count <= 253 else {
            return nil
        }
        guard candidate.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }) else {
            return nil
        }

        return candidate
    }

    func open(request: BassetRequest, ingestEndpoint: String) -> Transport? {
        guard
            let host = Self.hostname(ingestEndpoint),
            let token = request.requestToken,
            let http2 =
            URL(string: "https://\(host):\(config.http2Port)/frames")
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
}
