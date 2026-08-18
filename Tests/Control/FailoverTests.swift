@testable import Basset
import Foundation
import Testing

private final class Channel: RacedTransport, @unchecked Sendable {
    var onReady: (@Sendable () -> Void)?
    var onFailure: (@Sendable () -> Void)?

    let kind: TransportType?
    var note: String? = "fake"
    var refused: String?
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

/// Hands out queued connections in order and counts how many were requested.
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

/// QUIC takes time to connect; at_launch readings taken meanwhile are what these test.
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

    /// A late failure is free — ingest routes on the request token, not the connection.
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

    /// QUIC idles closed after 30s; without retry, one quiet spell strands it forever.
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

    /// Once the ingest cap lands, retrying the primary buys nothing — the request is already done.
    @Test func aTerminalRefusalStopsFurtherPrimaryRetries() {
        let quic = Channel(kind: .quic)
        let http2 = Channel(kind: .http2)
        let attempts = Attempts([quic])
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

        quic.fail()
        http2.refused = "max_frames"
        #expect(transport.refused == "max_frames")

        clock.now = clock.now.addingTimeInterval(30)
        transport.send(reading(2))

        #expect(
            attempts.taken == 1,
            "a latched refusal is terminal — no further QUIC dial is worth it"
        )
        #expect(transport.kind == .http2)
        #expect(transport.refused == "max_frames")
    }

    /// The ingest cap is final for the request; a redial already racing must not erase it.
    @Test func aTerminalRefusalSurvivesARecarryAlreadyInFlight() {
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

        quic.fail()
        clock.now = clock.now.addingTimeInterval(30)
        transport.send(reading(2))
        #expect(attempts.taken == 2, "past the cooldown, QUIC is dialled again")

        // The ingest cap lands on http2 while the redial above is still connecting.
        http2.refused = "max_frames"
        reconnected.becomeReady()

        #expect(transport.kind == .quic, "the redial still takes over the stream")
        #expect(
            transport.refused == "max_frames",
            "the fallback's terminal refusal must survive the switch to a transport reporting none"
        )

        transport.send(reading(3))
        #expect(attempts.taken == 2, "a latched refusal stops any further primary retry")
    }

    /// "QUIC failed" alone can't distinguish about-to-retry from stuck-until-a-reading.
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

    /// Sending, carrying, and abandoning overlap by design; nothing is lost between them.
    @Test func sendingWhileTheRaceResolvesLosesNothing() {
        let (transport, quic, http2) = subject()
        transport.start()

        let sends = 512
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            switch index {
            case 0: quic.becomeReady()
            case 1: quic.fail()
            default:
                for byte in 0 ..< sends {
                    transport.send(reading(UInt8(byte % 256)))
                }
            }
        }

        #expect(
            quic.count + http2.count + transport.dropped == sends * 6,
            "every reading was carried, held then flushed, or counted as dropped"
        )
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
