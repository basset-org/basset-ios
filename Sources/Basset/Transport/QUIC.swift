import BassetECS
import Foundation
import Network

/// Raw QUIC, not HTTP/3: frames go directly on the stream, so the request token
/// rides in-band as the first length-prefixed record rather than in a header.
final class QUICChannel: RacedTransport, @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onFailure: (@Sendable () -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let header: Data
    private let readyTimeout: DispatchTimeInterval
    private let lock: NSLock = .init()
    private var ready = false
    private var sentHeader = false
    private var givingUp: DispatchWorkItem?
    private var history: [String] = []

    var kind: TransportType? {
        .quic
    }

    var note: String? {
        lock.lock()
        defer { lock.unlock() }
        return history.isEmpty ? nil : history.joined(separator: " → ")
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    init(
        host: String,
        port: UInt16,
        token: String,
        queue: DispatchQueue,
        readyTimeout: DispatchTimeInterval = .seconds(3)
    ) {
        self.queue = queue
        self.readyTimeout = readyTimeout
        self.header = FrameEncoder().connectionHeader(token: token)
        let options = NWProtocolQUIC.Options(alpn: ["basset"])
        // Left at Network.framework's default, bidirectional. The device only
        // ever writes, so `.unidirectional` describes this traffic honestly —
        // but on iOS 27.0 a connection opened that way reached `.ready` and then
        // failed with ENOTCONN before a byte arrived, every time, on hardware.
        let parameters = NWParameters(quic: options)
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: parameters
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.note(state)
            switch state {
            case .ready:
                self?.markReady()
                self?.sendHeader()
                self?.onReady?()
            case .cancelled,
                 .failed:
                self?.onFailure?()
            // `waiting` is "no usable path yet", which every connection passes
            // through. A network that drops UDP stays here forever, so it gets a
            // deadline rather than being either trusted or abandoned.
            case .waiting:
                self?.giveUpIfStillWaiting()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Data) {
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    /// Every state the connection passed through, kept so an app can show why
    /// QUIC was abandoned. Without it the only evidence is Network.framework's
    /// console noise on a tethered run — the one run at_launch cannot be tested on.
    private func note(_ state: NWConnection.State) {
        let described =
            switch state {
            case .setup: "setup"
            case .preparing: "preparing"
            case .ready: "ready"
            case .waiting(let error): "waiting: \(error)"
            case .failed(let error): "failed: \(error)"
            case .cancelled: "cancelled"
            @unknown default: "unknown"
            }

        lock.lock()
        history.append(described)
        if history.count > 8 {
            history.removeFirst()
        }
        lock.unlock()
    }

    private func markReady() {
        lock.lock()
        ready = true
        givingUp?.cancel()
        givingUp = nil
        lock.unlock()
    }

    private func giveUpIfStillWaiting() {
        lock.lock()
        guard !ready, givingUp == nil else {
            lock.unlock()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else {
                return
            }

            self.onFailure?()
        }
        givingUp = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + readyTimeout, execute: work)
    }

    /// Written straight onto the connection rather than dispatched: the token is
    /// the first thing read off the stream and everything after it is a frame.
    /// One hop of delay puts it behind the backlog `onReady` flushes, the far end
    /// reads a frame's bytes as the token and rejects the stream, and the device
    /// never learns — the connection stays up and the readings go nowhere.
    private func sendHeader() {
        lock.lock()
        let already = sentHeader
        sentHeader = true
        lock.unlock()

        guard !already else {
            return
        }

        connection.send(content: header, completion: .contentProcessed { _ in })
    }
}
