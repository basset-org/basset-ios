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
    private var waiting: [(bytes: Data, frames: Int)]
    /// Posted but not yet answered — still owed to disk until success or a permanent refusal.
    private var inFlight: [UInt64: (bytes: Data, frames: Int)] = [:]
    private var nextInFlightId: UInt64 = 0
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
    init(
        endpoint: URL,
        token: String,
        requestId: UInt64,
        session: URLSession? = nil,
        backlogDirectory: URL = PersistedBacklog.defaultDirectory()
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

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else {
                return
            }

            self?.reconnected()
        }
        pathMonitor.start(queue: queue)

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
            // Cancelled while offline means discard, same as the in-memory buffers upstream.
            PersistedBacklog.remove(for: requestId, in: backlogDirectory)
        }
    }

    private func flush() {
        guard refusal == nil else {
            return
        }

        // Oldest first, so a retry doesn't reorder a capture behind whatever arrived since.
        // Left on disk exactly as it already was — still unconfirmed, not yet delivered.
        let queued = waiting
        waiting = []
        for batch in queued {
            let id = nextInFlightId
            nextInFlightId += 1
            inFlight[id] = batch
            post(batch.bytes, frames: batch.frames, inFlightId: id)
        }

        guard !pending.isEmpty else {
            return
        }

        let batch = pending
        let frames = pendingFrames
        pending = Data()
        pendingFrames = 0
        post(batch, frames: frames, inFlightId: nil)
    }

    private func post(_ batch: Data, frames: Int, inFlightId: UInt64?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")

        session.uploadTask(with: request, from: batch) { [weak self] _, response, error in
            self?.answered(
                batch,
                frames: frames,
                inFlightId: inFlightId,
                response: response,
                error: error
            )
        }
        .resume()
    }

    private func answered(
        _ batch: Data,
        frames: Int,
        inFlightId: UInt64?,
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
                hold(batch, frames: frames, inFlightId: inFlightId)
                return
            }

            switch http.statusCode {
            case 200 ..< 300:
                backoff = 1
                settled(inFlightId)
            // Final for this request: max_readings counts across every device and transport.
            case 429:
                refusal = "max_frames"
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
                hold(batch, frames: frames, inFlightId: inFlightId)
            default:
                // A 4xx this client cannot fix by asking again.
                lost += frames
                settled(inFlightId)
            }
        }
    }

    /// A batch nothing will touch again, delivered or written off — no longer owed to disk.
    private func settled(_ inFlightId: UInt64?) {
        guard let inFlightId, inFlight.removeValue(forKey: inFlightId) != nil else {
            return
        }

        persistBacklog()
    }

    private func hold(_ batch: Data, frames: Int, inFlightId: UInt64?) {
        if let inFlightId {
            inFlight.removeValue(forKey: inFlightId)
        }
        waiting.append((bytes: batch, frames: frames))

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

    private func persistBacklog() {
        PersistedBacklog.save(
            waiting + Array(inFlight.values),
            for: requestId,
            in: backlogDirectory
        )
    }
}
