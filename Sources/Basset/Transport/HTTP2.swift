import BassetECS
import Foundation
import Network

/// Readings batched into POSTs. A failed POST is retried, not discarded — worth capturing.
final class HTTP2Channel: Transport, @unchecked Sendable {
    private let endpoint: URL
    private let token: String
    private let requestId: UInt64
    private let backlogDirectory: URL
    private let session: URLSession
    private let queue: DispatchQueue = .init(label: QueueLabel.http2)
    private let pathMonitor: NWPathMonitor = .init()

    private var pending: Data = .init()
    private var pendingFrames = 0
    /// `sequence` is assigned once, when a batch first leaves `pending`, and travels with it
    /// through every retry — the persisted order follows it, not which of the two sets a
    /// batch currently sits in.
    private var waiting: [(sequence: UInt64, bytes: Data, frames: Int)]
    /// Posted but not yet answered — still owed to disk until success or a permanent refusal.
    private var inFlight: [UInt64: (bytes: Data, frames: Int)] = [:]
    /// Starts at 1: a rehydrated backlog is seeded at 0, always the oldest thing in play.
    private var nextSequence: UInt64 = 1
    private var flushScheduled = false
    private var retryWorkItem: DispatchWorkItem?
    private var backoff: TimeInterval = 1
    private var closed = false
    private var refusal: String?
    private var lost = 0

    private let flushAfter: DispatchTimeInterval = .milliseconds(500)
    private let flushAt = 32 * 1024
    private let maxWaitingBytes = 512 * 1024
    private let maxBackoff: TimeInterval = 30

    var kind: TransportType? {
        .http2
    }

    var refused: String? {
        queue.sync { refusal }
    }

    /// Surfaced rather than inferred: eviction and a permanently refused batch look alike outside.
    var dropped: Int {
        queue.sync { lost }
    }

    /// Injectable so retry can be driven against refusals otherwise only reachable on a train.
    /// `monitorsPath` is false only in tests: a headless CI simulator has no session to grant
    /// Network.framework's local-network permission, and the first `NWPathMonitor.start()` in
    /// the process can stall the whole run for an unbounded stretch waiting on it — `reconnected()`
    /// is exercised directly there instead.
    init(
        endpoint: URL,
        token: String,
        requestId: UInt64,
        session: URLSession? = nil,
        backlogDirectory: URL = PersistedBacklog.defaultDirectory(),
        monitorsPath: Bool = true
    ) {
        self.endpoint = endpoint
        self.token = token
        self.requestId = requestId
        self.backlogDirectory = backlogDirectory
        self.session = session ?? URLSession(
            configuration: .ephemeral,
            delegate: RedirectRefusal.shared,
            delegateQueue: nil
        )
        IgnoredSessions.add(self.session)
        waiting = PersistedBacklog.load(for: requestId, in: backlogDirectory)
            .map { (sequence: 0, bytes: $0.bytes, frames: $0.frames) }

        if monitorsPath {
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else {
                    return
                }

                self?.reconnected()
            }
            pathMonitor.start(queue: queue)
        }

        guard !waiting.isEmpty else {
            return
        }

        // A backlog surviving a relaunch is worth an attempt now, not a fresh backoff wait.
        queue.async { [self] in flush() }
    }

    /// Reachability regained: worth a try now rather than waiting out whatever backoff is left.
    func reconnected() {
        queue.async { [self] in
            guard !closed, !waiting.isEmpty else {
                return
            }

            retryWorkItem?.cancel()
            retryWorkItem = nil
            backoff = 1
            flush()
        }
    }

    func send(_ frame: Data) {
        queue.async { [self] in
            guard !closed, refusal == nil else {
                return
            }

            pending.append(frame)
            pendingFrames += 1

            if pending.count >= flushAt {
                flush()
                return
            }
            guard !flushScheduled else {
                return
            }

            flushScheduled = true
            queue.asyncAfter(deadline: .now() + flushAfter) { [self] in
                flushScheduled = false
                flush()
            }
        }
    }

    func close() {
        queue.async { [self] in
            flush()
            closed = true
            pathMonitor.cancel()
            // Nothing still in flight is worth carrying past a transport that's gone —
            // a leftover task otherwise runs to completion for nothing.
            session.invalidateAndCancel()
            // Cancelled while offline means discard, same as the in-memory buffers upstream.
            PersistedBacklog.remove(for: requestId, in: backlogDirectory)
        }
    }

    private func flush() {
        guard refusal == nil else {
            return
        }

        // Left on disk exactly as it already was — still unconfirmed, not yet delivered.
        let queued = waiting
        waiting = []
        for batch in queued {
            inFlight[batch.sequence] = (bytes: batch.bytes, frames: batch.frames)
            post(batch.bytes, frames: batch.frames, sequence: batch.sequence)
        }

        guard !pending.isEmpty else {
            return
        }

        let sequence = nextSequence
        nextSequence += 1
        let batch = pending
        let frames = pendingFrames
        pending = Data()
        pendingFrames = 0
        // Never yet on disk, unlike a retry drained from `waiting` above — owed there now.
        inFlight[sequence] = (bytes: batch, frames: frames)
        persistBacklog()
        post(batch, frames: frames, sequence: sequence)
    }

    private func post(_ batch: Data, frames: Int, sequence: UInt64) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")

        session.uploadTask(with: request, from: batch) { [weak self] _, response, error in
            self?.answered(
                batch,
                frames: frames,
                sequence: sequence,
                response: response,
                error: error
            )
        }
        .resume()
    }

    private func answered(
        _ batch: Data,
        frames: Int,
        sequence: UInt64,
        response: URLResponse?,
        error: Error?
    ) {
        queue.async { [self] in
            guard !closed else {
                return
            }
            guard let http = response as? HTTPURLResponse else {
                // No response: offline, DNS, a lost connection. Next attempt usually succeeds.
                _ = error
                hold(batch, frames: frames, sequence: sequence)
                return
            }

            switch http.statusCode {
            case 200 ..< 300:
                backoff = 1
                settled(sequence)
            // Final for this request: max_readings counts across every device and transport.
            case 429:
                refusal = "max_frames"
                // Removed first: otherwise this very batch would be summed twice below.
                inFlight.removeValue(forKey: sequence)
                lost += frames + pendingFrames
                pending = Data()
                pendingFrames = 0
                waiting.forEach { lost += $0.frames }
                inFlight.values.forEach { lost += $0.frames }
                waiting = []
                inFlight = [:]
                persistBacklog()
            // 401 is the token expiring, which the next PUT /device fixes — worth retrying.
            case 401,
                 408,
                 500...599:
                hold(batch, frames: frames, sequence: sequence)
            default:
                // A 4xx this client cannot fix by asking again.
                lost += frames
                settled(sequence)
            }
        }
    }

    /// A batch nothing will touch again, delivered or written off — no longer owed to disk.
    private func settled(_ sequence: UInt64) {
        guard inFlight.removeValue(forKey: sequence) != nil else {
            return
        }

        persistBacklog()
    }

    private func hold(_ batch: Data, frames: Int, sequence: UInt64) {
        inFlight.removeValue(forKey: sequence)
        waiting.append((sequence: sequence, bytes: batch, frames: frames))

        // Bounded, oldest-first: an hour offline must not grow memory unboundedly.
        var held = waiting.reduce(0) { $0 + $1.bytes.count }
        while held > maxWaitingBytes, let oldest = waiting.first {
            lost += oldest.frames
            held -= oldest.bytes.count
            waiting.removeFirst()
        }
        persistBacklog()

        // Replaced rather than left in place: a reconnect that fails again still gets a
        // fresh, short retry instead of waiting out whatever the old backoff had left.
        retryWorkItem?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        let item = DispatchWorkItem { [self] in flush() }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Sorted so a crash-recovered capture reads in the order it was taken, not the order
    /// retries happened to resolve in.
    private func persistBacklog() {
        let outstanding = (
            waiting.map { (sequence: $0.sequence, bytes: $0.bytes, frames: $0.frames) }
                + inFlight
                .map { (sequence: $0.key, bytes: $0.value.bytes, frames: $0.value.frames) }
        )
        .sorted { $0.sequence < $1.sequence }
        .map { (bytes: $0.bytes, frames: $0.frames) }

        PersistedBacklog.save(outstanding, for: requestId, in: backlogDirectory)
    }
}
