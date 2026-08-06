import Foundation

// QUIC first, HTTP/2 when it will not connect. The two failure populations are
// disjoint — inspection proxies drop UDP, some networks allow only 443 — so
// carrying both is what reaches the whole fleet rather than most of it.
//
// Frames sent before QUIC is ready are held rather than dropped: an at_launch
// instrument has already emitted by the time any connection is up.

/// What the failover needs of its first choice beyond sending: a way to start,
/// and the two answers that decide whether it is the one carrying frames.
protocol RacedTransport: Transport {
    var onReady: (@Sendable () -> Void)? { get set }
    var onFailure: (@Sendable () -> Void)? { get set }
    func start()
}

final class FailoverTransport: Transport, @unchecked Sendable {
    /// A note alone cannot say whether QUIC was set aside a moment ago or half an
    /// hour ago and never retried since. Both leave the same text behind.
    enum PrimaryState: Equatable, Sendable {
        case connecting
        case carrying
        case setAside(attempts: Int, retryOnNextSend: Bool)
    }

    private let makePrimary: @Sendable () -> any RacedTransport
    private let fallback: Transport
    private let retryAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let lock: NSLock = .init()

    private var primary: (any RacedTransport)?
    private var active: Transport?
    private var held: [Data] = []
    private var lastNote: String?
    private var refusedAt: Date?
    private var closed = false
    private var evicted = 0
    private var attempts = 0
    private let maxHeld = 1024

    var primaryState: PrimaryState {
        lock.lock()
        defer { lock.unlock() }
        if let primary {
            return primary === active ? .carrying : .connecting
        }
        return .setAside(attempts: attempts, retryOnNextSend: mayRetryPrimary())
    }

    var kind: TransportType? {
        lock.lock()
        defer { lock.unlock() }
        return active?.kind
    }

    var isReady: Bool {
        lock.lock()
        let current = active
        lock.unlock()
        return current?.isReady ?? false
    }

    /// Always QUIC's, whichever transport ended up carrying: the question is why
    /// the first choice was not taken. Kept after the connection is gone,
    /// because that is when it gets asked.
    var note: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = primary?.note ?? lastNote else {
            return nil
        }
        guard primary == nil else {
            return text
        }

        let tried = attempts == 1 ? "1 attempt" : "\(attempts) attempts"
        let next = mayRetryPrimary()
            ? "retries on the next reading"
            : "retried \(Int(retryAfter))s after an attempt, and only on a reading"
        return "\(text) — set aside after \(tried), \(next)"
    }

    var refused: String? {
        lock.lock()
        let current = active
        lock.unlock()
        return current?.refused
    }

    /// Evicted here while nothing could carry, plus whatever the transport that
    /// ended up carrying lost on its own.
    var dropped: Int {
        lock.lock()
        let mine = evicted
        let current = active
        lock.unlock()
        return mine + (current?.dropped ?? fallback.dropped)
    }

    init(
        primary makePrimary: @escaping @Sendable () -> any RacedTransport,
        fallback: Transport,
        retryAfter: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makePrimary = makePrimary
        self.fallback = fallback
        self.retryAfter = retryAfter
        self.now = now
    }

    /// Nothing reaches QUIC until it is ready. Sooner buries the frames in
    /// NWConnection's own send queue, where a later failover cannot reach them —
    /// losing exactly the readings taken while the connection establishes.
    func start() {
        attemptPrimary()
    }

    func send(_ frame: Data) {
        lock.lock()
        // An idle QUIC connection is closed by both ends after 30s, which is
        // ordinary for readings that arrive in bursts, so a quiet request has to
        // be able to come back. Retried on a send, never on a timer: a device
        // with nothing to say holds no connection and wakes no radio.
        let shouldRetry = mayRetryPrimary()

        guard let active else {
            if held.count >= maxHeld {
                held.removeFirst()
                evicted += 1
            }
            held.append(frame)
            lock.unlock()
            if shouldRetry {
                attemptPrimary()
            }
            return
        }

        lock.unlock()

        active.send(frame)
        if shouldRetry {
            attemptPrimary()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let current = active
        let candidate = primary
        active = nil
        primary = nil
        held = []
        lock.unlock()

        current?.close()
        candidate?.close()
        fallback.close()
    }

    private func mayRetryPrimary() -> Bool {
        active === fallback
            && primary == nil
            && !closed
            && (refusedAt.map { now().timeIntervalSince($0) >= retryAfter } ?? false)
    }

    private func attemptPrimary() {
        let candidate = makePrimary()
        lock.lock()
        guard !closed, primary == nil else {
            lock.unlock()
            return
        }

        primary = candidate
        attempts += 1
        lock.unlock()

        candidate.onReady = { [weak self, weak candidate] in
            guard let candidate else {
                return
            }

            self?.carry(over: candidate)
        }
        candidate.onFailure = { [weak self, weak candidate] in
            self?.abandon(candidate)
        }
        candidate.start()
    }

    private func carry(over transport: any RacedTransport) {
        lock.lock()
        // Only the connection currently being raced may take the stream. A
        // `ready` from an abandoned one arrives after the fallback has the
        // backlog, and honouring it hands readings to a socket nobody reads.
        guard !closed, primary === transport else {
            lock.unlock()
            return
        }

        active = transport
        let backlog = held
        held = []
        lock.unlock()
        backlog.forEach(transport.send)
    }

    /// A QUIC connection that fails after it started carrying still has to be
    /// abandoned. Splitting a request across two connections costs nothing —
    /// ingest routes on the request token and the encoder interns nothing across
    /// frames — where a dead socket costs every reading from that moment on.
    private func abandon(_ candidate: (any RacedTransport)?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }

        lastNote = candidate?.note ?? lastNote
        candidate?.onReady = nil
        candidate?.onFailure = nil
        primary = nil
        refusedAt = now()

        let backlog = held
        held = []
        active = fallback
        lock.unlock()

        candidate?.close()
        backlog.forEach(fallback.send)
    }
}
