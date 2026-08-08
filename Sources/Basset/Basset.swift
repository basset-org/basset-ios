@_exported import BassetECS
import Foundation

public struct Config: Sendable {
    public var apiKey: String
    public var control: URL
    public var quicPort: UInt16
    public var http2Port: UInt16

    /// Ports are defaults, not discoveries: the control plane names the ingest
    /// host but not the port it listens on. High UDP with TCP alongside, because
    /// inspection middleboxes drop UDP/443 specifically to force clients back
    /// onto TCP where TLS can be intercepted.
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
    /// Held across `start`, which is what keeps the loop unreachable until it
    /// has read what the last run persisted. Publishing it any earlier lets an
    /// `identify` on another thread converge a control response that
    /// `startFromDisk` then replaces with what was on disk.
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var loop: DeviceLoop?

    public static func start(apiKey: String) {
        start(Config(apiKey: apiKey))
    }

    public static func start(_ config: Config) {
        // The port reads only from the main thread, and a request arrives long
        // after launch — by which time the main thread may be the thing that has
        // stopped answering. Taken here, while the app is still healthy.
        MainThreadPort.capture()

        // Before any request can arrive, so an instrument activating later reads
        // the state the app is actually in rather than assuming the one it
        // would have been in had the request been there at launch.
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

    /// Associates this device with one of your users, so a request can target
    /// them by id. An attribute change like any other, so it rides the same
    /// upsert rather than a call of its own.
    public static func identify(userId: String?) {
        lock.lock()
        let running = loop
        lock.unlock()
        running?.identify(userId: userId)
    }

    /// What the SDK is doing, for an app that wants to show it. Read-only —
    /// nothing here activates an instrument. Nil until `start`.
    public static func currentState() -> DeviceState? {
        lock.lock()
        let running = loop
        lock.unlock()
        return running?.currentState()
    }
}

/// Launch, then upsert, then hold. Everything the device asks the control plane
/// is one of those three.
final class DeviceLoop: @unchecked Sendable {
    private struct State {
        var userId: String?
        var lastCtrlResponse: CtrlResponse?
        var ingestEndpoint: String?
    }

    private let config: Config
    private let control: ControlClient
    private let identity: DeviceIdentity
    private let runner: InstrumentRunner
    private let guarded: Mutex<State> = .init(State())
    private var following: Task<Void, Never>?

    init(config: Config) {
        self.config = config
        self.identity = DeviceIdentity.current()
        self.control = ControlClient(endpoint: config.control, apiKey: config.apiKey)
        self.runner = InstrumentRunner(opener: IngestTransports(config: config))
    }

    func start() {
        // Before the network: an at_launch instrument that waited for a response
        // would be measuring something already over.
        runner.startFromDisk()

        following = Task.detached(priority: .utility) { [self] in
            await follow()
        }
    }

    func identify(userId: String?) {
        guarded.withLock { $0.userId = userId }

        Task.detached(priority: .utility) { [self] in
            _ = try? await upsert()
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

    private func upsert() async throws -> String {
        let user = guarded.withLock { $0.userId }

        let response: DeviceResponse
        do {
            response = try await control.putDevice(identity, userId: user)
        } catch {
            record(.putDevice, outcome(for: error))
            throw error
        }

        record(.putDevice, .accepted(requestCount: response.requests.count))
        runner.converge(to: response.requests, ingestEndpoint: response.ingestEndpoint)
        guarded.withLock { $0.ingestEndpoint = response.ingestEndpoint }
        return response.deviceToken
    }

    private func record(_ call: CtrlResponse.Call, _ outcome: CtrlResponse.Outcome) {
        guarded.withLock {
            $0.lastCtrlResponse = CtrlResponse(call: call, outcome: outcome, at: Date())
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
        case .none:
            .unreachable(error.localizedDescription)
        }
    }

    private func follow() async {
        var backoff = Duration.seconds(1)

        while !Task.isCancelled {
            do {
                let deviceToken = try await upsert()
                backoff = .seconds(1)

                // Held reads until the device token expires or the device is
                // refused. The answer arrives when the desired state changes or
                // when the hold runs out, and either one is the complete list.
                while !Task.isCancelled {
                    let requests: [BassetRequest]
                    do {
                        requests = try await control.requests(deviceToken: deviceToken)
                    } catch {
                        record(.requests, outcome(for: error))
                        throw error
                    }

                    record(.requests, .accepted(requestCount: requests.count))
                    let endpoint = guarded.withLock { $0.ingestEndpoint }
                    runner.converge(to: requests, ingestEndpoint: endpoint)
                }
            } catch ControlError.unauthorized {
                // No refresh token exists: re-upserting is the refresh, and the
                // next iteration makes that call anyway.
                continue
            } catch {
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }
}

/// One stream per request, each opened with that request's own token. Ingest
/// routes on it, so a device token cannot write readings and one request cannot
/// write into another's stream.
struct IngestTransports: TransportOpener {
    let config: Config

    /// The ingest host arrives as a name the device pastes into a URL. A name
    /// carrying a slash, an `@` or a colon is not a host and does not make that
    /// URL mean what it reads as, so anything that is not a hostname opens no
    /// stream and the readings stay held.
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

        // A closure, not an instance: an NWConnection cannot be restarted once it
        // has failed, and a QUIC connection that idles out is the normal end of a
        // quiet spell — so returning to QUIC means building a new one.
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
            fallback: HTTP2Channel(endpoint: http2, token: token)
        )
        transport.start()
        return transport
    }
}
