import Basset
import Foundation
import Network

#if DEBUG
/// One connection at a time: a second machine attaching to the same app would fight
/// the first over which instruments run.
final class AttachedLink: AttachedChannel, @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock: NSLock = .init()
    private var connection: NWConnection?
    private var reader: LengthPrefixedReader = .init()

    init() throws {
        var opened: NWListener?
        var chosen: UInt16 = BassetAttached.firstPort
        let queue = DispatchQueue(label: "dev.basset.attached")

        for offset in 0 ..< BassetAttached.portsToTry {
            let candidate = BassetAttached.firstPort + UInt16(offset)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: candidate)!
            )
            guard let listener = try? NWListener(using: parameters) else {
                continue
            }

            // An NWListener binds when it starts, not when it is made, so a port
            // already taken is only reported here. Without waiting, every attached
            // app would believe it had the first port.
            if AttachedLink.bound(listener, on: queue) {
                opened = listener
                chosen = candidate
                break
            }

            listener.cancel()
        }

        guard let opened else {
            throw BassetAttached.Failure.noFreePort(
                from: BassetAttached.firstPort,
                tried: BassetAttached.portsToTry
            )
        }

        listener = opened
        port = chosen
        self.queue = queue

        opened.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    private static func bound(_ listener: NWListener, on queue: DispatchQueue) -> Bool {
        let settled = DispatchSemaphore(value: 0)
        let outcome = NSLock()
        var ready = false

        // A listener without one never leaves setup, so the real handler is installed
        // once a port is settled and this one only has to exist.
        listener.newConnectionHandler = { _ in }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.withLock { ready = true }
                settled.signal()
            case .cancelled,
                 .failed:
                settled.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard settled.wait(timeout: .now() + 2) == .success else {
            return false
        }

        return outcome.withLock { ready }
    }

    func stop() {
        AttachedBridge.close(self)
        lock.withLock {
            connection?.cancel()
            connection = nil
            reader = LengthPrefixedReader()
        }
        listener.cancel()
    }

    func send(_ frame: Data) {
        let open = lock.withLock { connection }
        open?.send(content: frame, completion: .idempotent)
    }

    private func isCurrent(_ candidate: NWConnection) -> Bool {
        lock.withLock { connection === candidate }
    }

    private func accept(_ incoming: NWConnection) {
        lock.withLock {
            connection?.cancel()
            connection = incoming
            reader = LengthPrefixedReader()
        }
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else {
                    return
                }

                AttachedBridge.open(self)
            case .cancelled,
                 .failed:
                AttachedBridge.close()
            default:
                break
            }
        }
        incoming.start(queue: queue)
        receive(on: incoming)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] chunk, _, isComplete, error in
            guard let self else {
                return
            }

            if let chunk, !chunk.isEmpty {
                lock.withLock { self.reader.append(chunk) }
                drain()
            }
            guard error == nil, !isComplete else {
                if isCurrent(connection) {
                    AttachedBridge.close(self)
                }
                return
            }

            receive(on: connection)
        }
    }

    private func drain() {
        while true {
            let document: Data?
            do {
                document = try lock.withLock { try reader.next() }
            } catch {
                lock.withLock { connection?.cancel() }
                return
            }
            guard let document else {
                return
            }

            try? AttachedBridge.apply(document)
        }
    }
}
#endif
