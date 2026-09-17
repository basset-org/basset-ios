import Basset
import Foundation
import Network

#if DEBUG
/// One connection at a time: a second machine attaching to the same app would fight
/// the first over which instruments run.
final class AttachedLink: AttachedChannel, @unchecked Sendable {
    /// A machine that stops reading must not grow this process's memory: frames past
    /// this many unacknowledged writes are dropped rather than queued.
    static let inFlightLimit = 256

    let port: UInt16

    /// Called on the link's queue when the listener dies for a reason other than `stop()`.
    private let onFailure: (AttachedLink) -> Void
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock: NSLock = .init()
    private let ended: DispatchSemaphore = .init(value: 0)
    private var closed = false
    private var connection: NWConnection?
    private var inFlight = 0
    private var reader: LengthPrefixedReader = .init()

    init(onFailure: @escaping (AttachedLink) -> Void = { _ in }) throws {
        self.onFailure = onFailure
        var opened: NWListener?
        var chosen: UInt16 = BassetAttached.firstPort
        let queue = DispatchQueue(label: "dev.basset.attached")

        for offset in 0 ..< BassetAttached.portsToTry {
            let candidate = BassetAttached.firstPort + UInt16(offset)
            guard AttachedLink.isFree(candidate) else {
                continue
            }

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
        // Suspension closes the socket, a hung main never rebinds it; reported on the link's queue.
        opened.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled,
                 .failed:
                self?.ended.signal()
                self?.reportFailure()
            default:
                break
            }
        }
    }

    /// A plain bind answers quietly; NWListener logs a failure for every port that is
    /// taken, and with several attached apps on one machine most of the walk is taken.
    private static func isFree(_ port: UInt16) -> Bool {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else {
            return true
        }

        defer { close(handle) }

        var one: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
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
        detached()
        lock.withLock {
            closed = true
            connection?.cancel()
            connection = nil
            reader = LengthPrefixedReader()
        }
        listener.cancel()
        // The port is free once the listener reports cancelled, not when cancel() returns;
        // binding the replacement before that lands it one port up.
        _ = ended.wait(timeout: .now() + 1)
    }

    func send(_ frame: Data) {
        let open = lock.withLock { () -> NWConnection? in
            guard let connection, inFlight < Self.inFlightLimit else {
                return nil
            }

            inFlight += 1
            return connection
        }
        open?.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else {
                return
            }

            lock.withLock { self.inFlight = max(0, self.inFlight - 1) }
        })
    }

    /// Nothing the attached machine put on the screen may outlive it.
    private func detached() {
        AttachedBridge.close(self)
        DrivingOverlay.hideFromAnyThread()
        KeepAwake.releaseFromAnyThread()
    }

    private func reportFailure() {
        let stopped = lock.withLock { closed }
        guard !stopped else {
            return
        }

        onFailure(self)
    }

    /// Only the current connection's end detaches the machine: a replaced connection
    /// reports cancelled after its successor is ready, and must not close the bridge
    /// the successor just opened.
    private func lost(_ candidate: NWConnection) {
        let wasCurrent = lock.withLock { () -> Bool in
            guard connection === candidate else {
                return false
            }

            connection = nil
            inFlight = 0
            return true
        }
        guard wasCurrent else {
            return
        }

        detached()
    }

    private func accept(_ incoming: NWConnection) {
        lock.withLock {
            connection?.cancel()
            connection = incoming
            inFlight = 0
            reader = LengthPrefixedReader()
        }
        incoming.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else {
                    return
                }

                AttachedBridge.identity().forEach(self.send)
                AttachedBridge.open(self)
            case .cancelled,
                 .failed:
                self?.lost(incoming)
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
                lost(connection)
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

            if AttachedCommands
                .handle(document, reply: { [weak self] frame in self?.send(frame) })
            {
                continue
            }

            try? AttachedBridge.apply(document)
        }
    }
}
#endif
