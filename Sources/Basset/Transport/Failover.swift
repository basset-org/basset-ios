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

    private struct State {
        var primary: (any RacedTransport)?
        var active: Transport?
        var held: [Data] = []
        var lastNote: String?
        var refusedAt: Date?
        var closed = false
        var evicted = 0
        var attempts = 0
    }

    private let makePrimary: @Sendable () -> any RacedTransport
    private let fallback: Transport
    private let retryAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let guarded: Mutex<State> = .init(State())
    private let maxHeld = 1024

    var primaryState: PrimaryState {
        guarded.withLock { state in
            if let primary = state.primary {
                return primary === state.active ? .carrying : .connecting
            }

            return .setAside(
                attempts: state.attempts,
                retryOnNextSend: mayRetryPrimary(state)
            )
        }
    }

    var kind: TransportType? {
        guarded.withLock { $0.active?.kind }
    }

    var isReady: Bool {
        guarded.withLock { $0.active }?.isReady ?? false
    }

    /// Always QUIC's, whichever transport ended up carrying: the question is why
    /// the first choice was not taken. Kept after the connection is gone,
    /// because that is when it gets asked.
    var note: String? {
        // The candidate's own note is read after the lock is released: asking a
        // transport for it takes that transport's lock, and holding this one
        // across the question nests them.
        let reported = guarded.withLock { state in
            (
                primary: state.primary,
                lastNote: state.lastNote,
                attempts: state.attempts,
                mayRetry: mayRetryPrimary(state)
            )
        }
        guard let text = reported.primary?.note ?? reported.lastNote else {
            return nil
        }
        guard reported.primary == nil else {
            return text
        }

        let tried = reported.attempts == 1 ? "1 attempt" : "\(reported.attempts) attempts"
        let next = reported.mayRetry
            ? "retries on the next reading"
            : "retried \(Int(retryAfter))s after an attempt, and only on a reading"
        return "\(text) — set aside after \(tried), \(next)"
    }

    var refused: String? {
        guarded.withLock { $0.active }?.refused
    }

    /// Evicted here while nothing could carry, plus whatever the transport that
    /// ended up carrying lost on its own.
    var dropped: Int {
        let (mine, current) = guarded.withLock { ($0.evicted, $0.active) }
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
        let (shouldRetry, active) = guarded.withLock { state -> (Bool, Transport?) in
            // An idle QUIC connection is closed by both ends after 30s, which is
            // ordinary for readings that arrive in bursts, so a quiet request has
            // to be able to come back. Retried on a send, never on a timer: a
            // device with nothing to say holds no connection and wakes no radio.
            let shouldRetry = mayRetryPrimary(state)
            guard let active = state.active else {
                if state.held.count >= maxHeld {
                    state.held.removeFirst()
                    state.evicted += 1
                }

                state.held.append(frame)
                return (shouldRetry, nil)
            }

            return (shouldRetry, active)
        }

        active?.send(frame)
        if shouldRetry {
            attemptPrimary()
        }
    }

    func close() {
        let (current, candidate) = guarded.withLock { state -> (
            Transport?,
            (any RacedTransport)?
        ) in
            state.closed = true
            let current = state.active
            let candidate = state.primary
            state.active = nil
            state.primary = nil
            state.held = []
            return (current, candidate)
        }

        current?.close()
        candidate?.close()
        fallback.close()
    }

    private func mayRetryPrimary(_ state: State) -> Bool {
        state.active === fallback
            && state.primary == nil
            && !state.closed
            && (state.refusedAt.map { now().timeIntervalSince($0) >= retryAfter } ?? false)
    }

    private func attemptPrimary() {
        let candidate = makePrimary()
        let taken = guarded.withLock { state -> Bool in
            guard !state.closed, state.primary == nil else {
                return false
            }

            state.primary = candidate
            state.attempts += 1
            return true
        }
        guard taken else {
            return
        }

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
        let backlog = guarded.withLock { state -> [Data]? in
            // Only the connection currently being raced may take the stream. A
            // `ready` from an abandoned one arrives after the fallback has the
            // backlog, and honouring it hands readings to a socket nobody reads.
            guard !state.closed, state.primary === transport else {
                return nil
            }

            state.active = transport
            let backlog = state.held
            state.held = []
            return backlog
        }

        backlog?.forEach(transport.send)
    }

    /// A QUIC connection that fails after it started carrying still has to be
    /// abandoned. Splitting a request across two connections costs nothing —
    /// ingest routes on the request token and the encoder interns nothing across
    /// frames — where a dead socket costs every reading from that moment on.
    private func abandon(_ candidate: (any RacedTransport)?) {
        // Asked before the lock is taken, for the reason `note` explains.
        let reported = candidate?.note
        let backlog = guarded.withLock { state -> [Data]? in
            guard !state.closed else {
                return nil
            }

            state.lastNote = reported ?? state.lastNote
            state.primary = nil
            state.refusedAt = now()

            let backlog = state.held
            state.held = []
            state.active = fallback
            return backlog
        }
        guard let backlog else {
            return
        }

        // Released after the candidate stopped being the primary, so a `ready`
        // still on its way finds nothing to carry rather than a live stream.
        candidate?.onReady = nil
        candidate?.onFailure = nil
        candidate?.close()
        backlog.forEach(fallback.send)
    }
}
