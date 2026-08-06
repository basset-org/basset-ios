import BassetECS
import Foundation

/// One request's readings, batched into POSTs. The request token rides in the
/// Authorization header here, where the QUIC path carries it in-band as the
/// first frame.
///
/// A failed POST is retried rather than discarded. A batch lost to a
/// wifi-to-cellular handover is exactly the condition worth capturing, and a
/// diagnostic tool that drops readings silently reports absence as "nothing
/// happened".
final class HTTP2Channel: Transport, @unchecked Sendable {
    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let queue: DispatchQueue = .init(label: QueueLabel.http2)

    private var pending: Data = .init()
    private var pendingFrames = 0
    private var waiting: [(bytes: Data, frames: Int)] = []
    private var flushScheduled = false
    private var retryScheduled = false
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

    /// Readings this transport accepted and could not deliver. Surfaced rather
    /// than inferred: eviction and a permanently refused batch look alike from
    /// the outside.
    var dropped: Int {
        queue.sync { lost }
    }

    /// Injectable so the retry path can be driven against refusals and outages
    /// that are otherwise only reachable on a train.
    init(endpoint: URL, token: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.session = session ?? URLSession(
            configuration: .ephemeral,
            delegate: RedirectRefusal.shared,
            delegateQueue: nil
        )
        IgnoredSessions.remember(self.session)
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
        }
    }

    private func flush() {
        guard refusal == nil else {
            return
        }

        // What is waiting from an earlier failure goes first, oldest to newest,
        // so a retry does not reorder a capture behind whatever arrived since.
        let queued = waiting
        waiting = []
        for batch in queued {
            post(batch.bytes, frames: batch.frames)
        }

        guard !pending.isEmpty else {
            return
        }

        let batch = pending
        let frames = pendingFrames
        pending = Data()
        pendingFrames = 0
        post(batch, frames: frames)
    }

    private func post(_ batch: Data, frames: Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")

        session.uploadTask(with: request, from: batch) { [weak self] _, response, error in
            self?.answered(batch, frames: frames, response: response, error: error)
        }
        .resume()
    }

    private func answered(
        _ batch: Data,
        frames: Int,
        response: URLResponse?,
        error: Error?
    ) {
        queue.async { [self] in
            guard !closed else {
                return
            }
            guard let http = response as? HTTPURLResponse else {
                // No response at all: offline, DNS, a connection lost mid-flight.
                // The next attempt seconds later usually succeeds, which is the
                // whole point of retrying a handover.
                _ = error
                hold(batch, frames: frames)
                return
            }

            switch http.statusCode {
            case 200 ..< 300:
                backoff = 1
            // The one refusal that is final for this request — max_readings
            // counts across every device and both transports, and nothing lowers
            // it again.
            case 429:
                refusal = "max_frames"
                lost += frames + pendingFrames
                pending = Data()
                pendingFrames = 0
                waiting.forEach { lost += $0.frames }
                waiting = []
            // The request token expiring, which the next PUT /device fixes, so
            // the batch is worth keeping rather than dropping.
            case 401,
                 408,
                 500...599:
                hold(batch, frames: frames)
            default:
                // A 4xx this client cannot fix by asking again.
                lost += frames
            }
        }
    }

    private func hold(_ batch: Data, frames: Int) {
        waiting.append((bytes: batch, frames: frames))

        // Bounded, and oldest-first: a device that has been offline for an hour
        // must not grow memory until it comes back, and the readings worth
        // keeping are the ones nearest the fault.
        var held = waiting.reduce(0) { $0 + $1.bytes.count }
        while held > maxWaitingBytes, let oldest = waiting.first {
            lost += oldest.frames
            held -= oldest.bytes.count
            waiting.removeFirst()
        }

        guard !retryScheduled else {
            return
        }

        retryScheduled = true
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            retryScheduled = false
            flush()
        }
    }
}
