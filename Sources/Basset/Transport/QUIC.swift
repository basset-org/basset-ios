import BassetECS
import Foundation
import Network

/// Raw QUIC, not HTTP/3: the request token rides in-band as the first length-prefixed record.
final class QUICChannel: RacedTransport, @unchecked Sendable {
    private struct State {
        var ready = false
        var sentHeader = false
        var givingUp: DispatchWorkItem?
        var history: [String] = []
    }

    var onReady: (@Sendable () -> Void)?
    var onFailure: (@Sendable () -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let header: Data
    private let readyTimeout: DispatchTimeInterval
    private let guarded: Mutex<State> = .init(State())

    var kind: TransportType? {
        .quic
    }

    var note: String? {
        guarded.withLock { $0.history.isEmpty ? nil : $0.history.joined(separator: " → ") }
    }

    var isReady: Bool {
        guarded.withLock { $0.ready }
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
        // Bidirectional, not `.unidirectional`: that failed with ENOTCONN on iOS 27.0 hardware.
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
            // A network that drops UDP stays in `.waiting` forever, so it gets a deadline.
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

    /// Every state the connection passed through, kept so an app can show why QUIC was abandoned.
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

        guarded.withLock { state in
            state.history.append(described)
            if state.history.count > 8 {
                state.history.removeFirst()
            }
        }
    }

    private func markReady() {
        guarded.withLock { state in
            state.ready = true
            state.givingUp?.cancel()
            state.givingUp = nil
        }
    }

    private func giveUpIfStillWaiting() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else {
                return
            }

            self.onFailure?()
        }
        let scheduled = guarded.withLock { state -> Bool in
            guard !state.ready, state.givingUp == nil else {
                return false
            }

            state.givingUp = work
            return true
        }
        guard scheduled else {
            return
        }

        queue.asyncAfter(deadline: .now() + readyTimeout, execute: work)
    }

    /// Sent directly, not dispatched: one hop of delay lets a frame's bytes get read as the token.
    private func sendHeader() {
        let already = guarded.withLock { state -> Bool in
            let already = state.sentHeader
            state.sentHeader = true
            return already
        }

        guard !already else {
            return
        }

        connection.send(content: header, completion: .contentProcessed { _ in })
    }
}
