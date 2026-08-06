@testable import Basset
import Foundation
import Testing

private final class Channel: RacedTransport, @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onFailure: (@Sendable () -> Void)?

    let kind: TransportType?
    var note: String? = "fake"
    private(set) var started = false

    private let lock: NSLock = .init()
    private var frames: [Data] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    init(kind: TransportType?) {
        self.kind = kind
    }

    func start() {
        started = true
    }

    func send(_ frame: Data) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func close() {}

    func becomeReady() {
        onReady?()
    }

    func fail() {
        onFailure?()
    }
}

private func reading(_ byte: UInt8) -> Data {
    Data([byte])
}

/// Hands out the connections a reconnecting failover asks for, in order, and
/// counts how many it was asked for.
private final class Attempts: @unchecked Sendable {
    private(set) var taken = 0

    private let lock: NSLock = .init()
    private var queued: [Channel]

    init(_ queued: [Channel]) {
        self.queued = queued
    }

    func next() -> any RacedTransport {
        lock.lock()
        defer { lock.unlock() }
        taken += 1
        return queued.isEmpty ? Channel(kind: .quic) : queued.removeFirst()
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date = .init(timeIntervalSince1970: 1785000000)
}

/// The QUIC connection takes time to establish, and an at_launch instrument has
/// already emitted by then. Where those first readings end up is the whole
/// question these cover.
struct FailoverTests {
    @Test func nothingIsHandedOverUntilTheConnectionIsReady() {
        let (transport, quic, http2) = subject()
        transport.start()

        transport.send(reading(1))
        transport.send(reading(2))

        #expect(quic.started)
        #expect(
            quic.count == 0,
            "NWConnection's own queue cannot be reclaimed by a failover"
        )
        #expect(http2.count == 0)
        #expect(transport.kind == nil, "nothing is carrying these yet")
    }

    @Test func readingsTakenWhileConnectingArriveOnceQuicIsReady() {
        let (transport, quic, http2) = subject()
        transport.start()
        transport.send(reading(1))
        transport.send(reading(2))

        quic.becomeReady()

        #expect(quic.count == 2)
        #expect(http2.count == 0)
        #expect(transport.kind == .quic)
    }

    @Test func readingsTakenWhileConnectingSurviveAFailover() {
        let (transport, quic, http2) = subject()
        transport.start()
        transport.send(reading(1))
        transport.send(reading(2))

        quic.fail()

        #expect(
            http2.count == 2,
            "the launch readings are exactly the ones worth keeping"
        )
        #expect(quic.count == 0)
        #expect(transport.kind == .http2)
    }

    /// A connection that fails after it started carrying costs a whole capture:
    /// QUIC reaches `.ready`, takes the frames, then fails, and every reading
    /// after it goes into a dead socket. Splitting a request across two
    /// connections costs nothing, since ingest routes on the request token.
    @Test func aFailureAfterQuicIsCarryingStillMovesToTheFallback() {
        let (transport, quic, http2) = subject()
        transport.start()
        quic.becomeReady()
        transport.send(reading(1))

        quic.fail()
        transport.send(reading(2))

        #expect(quic.count == 1, "what it already took is gone; what follows is not")
        #expect(http2.count == 1)
        #expect(transport.kind == .http2)
    }

    /// A QUIC connection is closed by both ends after 30s of silence, which is
    /// ordinary for readings that arrive in bursts. Without this, one quiet
    /// spell moved a request onto the fallback for the rest of its life.
    @Test func aQuietSpellDoesNotStrandTheRequestOnTheFallback() {
        let quic = Channel(kind: .quic)
        let http2 = Channel(kind: .http2)
        let reconnected = Channel(kind: .quic)
        let attempts = Attempts([quic, reconnected])
        let clock = Clock()

        let transport = FailoverTransport(
            primary: { attempts.next() },
            fallback: http2,
            retryAfter: 30,
            now: { clock.now }
        )
        transport.start()
        quic.becomeReady()
        transport.send(reading(1))

        // The connection idles out. Everything since goes over the fallback.
        quic.fail()
        transport.send(reading(2))
        #expect(transport.kind == .http2)

        // Still inside the cooldown, so nothing is dialled again.
        clock.now = clock.now.addingTimeInterval(10)
        transport.send(reading(3))
        #expect(
            attempts.taken == 1,
            "a hostile network must not be dialled on every reading"
        )

        clock.now = clock.now.addingTimeInterval(30)
        transport.send(reading(4))
        #expect(attempts.taken == 2, "past the cooldown, QUIC is tried again")

        reconnected.becomeReady()
        transport.send(reading(5))

        #expect(transport.kind == .quic, "and takes the stream back")
        #expect(reconnected.count == 1)
        #expect(http2.count == 3, "readings 2, 3 and 4 went over the fallback")
    }

    /// Two devices that both say "QUIC failed" can be in different situations:
    /// one is a second from being retried, the other will sit on the fallback
    /// until a reading arrives. A screen showing only the connection's own last
    /// words cannot tell them apart, and the difference is the whole diagnosis.
    @Test func theNoteSaysWhetherQuicIsComingBack() {
        let quic = Channel(kind: .quic)
        let http2 = Channel(kind: .http2)
        let clock = Clock()
        let transport = FailoverTransport(
            primary: { quic },
            fallback: http2,
            retryAfter: 30,
            now: { clock.now }
        )
        transport.start()
        #expect(transport.primaryState == .connecting)

        quic.becomeReady()
        #expect(transport.primaryState == .carrying)
        #expect(
            transport.note == "fake",
            "while it is carrying there is nothing to explain"
        )

        quic.fail()
        #expect(transport.primaryState == .setAside(attempts: 1, retryOnNextSend: false))
        #expect(transport.note?.contains("1 attempt") == true)
        #expect(transport.note?.contains("only on a reading") == true)

        clock.now = clock.now.addingTimeInterval(30)
        #expect(transport.primaryState == .setAside(attempts: 1, retryOnNextSend: true))
        #expect(transport.note?.contains("retries on the next reading") == true)
    }

    @Test func aLateReadyCannotTakeTheStreamBackFromTheFallback() {
        let (transport, quic, http2) = subject()
        transport.start()

        quic.fail()
        quic.becomeReady()
        transport.send(reading(1))

        #expect(http2.count == 1)
        #expect(quic.count == 0)
    }

    private func subject() -> (FailoverTransport, Channel, Channel) {
        let quic = Channel(kind: .quic)
        let http2 = Channel(kind: .http2)
        return (
            FailoverTransport(primary: { quic }, fallback: http2, now: { .distantPast }),
            quic,
            http2
        )
    }
}
