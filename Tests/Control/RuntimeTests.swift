@testable import Basset
import BassetECS
import Foundation
import Testing

private final class RecordingTransport: Transport, @unchecked Sendable {
    private(set) var closed = false
    let kind: TransportType?
    let isReady: Bool
    var refused: String?
    var dropped = 0

    private let lock: NSLock = .init()
    private var frames: [Data] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    var sent: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    init(kind: TransportType? = .quic, isReady: Bool = true) {
        self.kind = kind
        self.isReady = isReady
    }

    func refuse() {
        lock.lock()
        refused = "max_frames"
        lock.unlock()
    }

    func send(_ frame: Data) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

private final class RecordingOpener: TransportOpener, @unchecked Sendable {
    private let lock: NSLock = .init()
    private var opened: [UInt64: RecordingTransport] = [:]
    private let kind: TransportType?

    init(kind: TransportType? = .quic) {
        self.kind = kind
    }

    func open(request: BassetRequest, ingestEndpoint: String) -> Transport? {
        lock.lock()
        defer { lock.unlock() }
        let stream = RecordingTransport(kind: kind)
        opened[request.requestId] = stream
        return stream
    }

    func stream(_ requestId: UInt64) -> RecordingTransport? {
        lock.lock()
        defer { lock.unlock() }
        return opened[requestId]
    }
}

/// Instrument state lives on the instance the runtime owns, so a test double
/// records what happened to it in its own stored properties rather than in a
/// process-global. Reached through the runtime, which is what holds it.
private final class Recorder: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var observed = 0
    private var stops = 0
    private var context: Context?

    var observeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func observing(_ context: Context) {
        lock.lock()
        observed += 1
        self.context = context
        lock.unlock()
    }

    func stopped() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    func take() {
        lock.lock()
        let context = self.context
        lock.unlock()
        context?.emit { out in out.put(.detail("reading")) }
    }
}

private protocol FakeInstrument: StreamingInstrument {
    var recorder: Recorder { get }
}

extension FakeInstrument {
    func observe(_ context: Context) {
        recorder.observing(context)
    }

    func stopObserving() {
        recorder.stopped()
    }
}

private final class FakeMemory: FakeInstrument {
    static let id: InstrumentWireID = .memoryFootprint
    static let name = "memory.footprint"
    static let domain: Domain = .memory
    static let entity = Entity.WireID.process

    let recorder: Recorder = .init()

    init() {}
}

private final class FakeThermal: FakeInstrument {
    static let id: InstrumentWireID = .thermalState
    static let name = "power.thermalState"
    static let domain: Domain = .power
    static let entity = Entity.WireID.thermal

    let recorder: Recorder = .init()

    init() {}
}

/// A hooked class rather than a recorder, because the reading that doubles is
/// the one a swizzle produces: the runtime reuses a deactivated instrument's
/// context, so what the second activation does to the hook site is the whole
/// question.
@objc private class HookedSubject: NSObject {
    @objc dynamic func work() {}
}

private final class FakeHooked: StreamingInstrument {
    static let id: InstrumentWireID = .viewLayoutPass
    static let name = "uikit.view.layoutPass"
    static let domain: Domain = .uikit
    static let entity = Entity.WireID.process

    init() {}

    func observe(_ context: Context) {
        _ = context.swizzle
            .after(HookedSubject.self, #selector(HookedSubject.work)) { _ in
                context.emit { out in out.put(.detail("pass")) }
            }
    }

    func stopObserving() {}
}

/// The fault path: one instrument detects, the runtime asks whoever else is
/// active, and neither instrument names the other.
private final class FakeDetector: StreamingInstrument, @unchecked Sendable {
    static let id: InstrumentWireID = .mainThreadHang
    static let name = "concurrency.mainThreadHang"
    static let domain: Domain = .concurrency
    static let entity = Entity.WireID.mainThread

    private let lock: NSLock = .init()
    private var context: Context?

    init() {}

    func observe(_ context: Context) {
        lock.lock()
        self.context = context
        lock.unlock()
    }

    func stopObserving() {}

    func detect() {
        lock.lock()
        let context = self.context
        lock.unlock()
        context?.fault(.hang)
    }
}

private final class FakeContributor: FaultInstrument, @unchecked Sendable {
    static let id: InstrumentWireID = .threadSnapshot
    static let name = "runtime.threadSnapshot"
    static let domain: Domain = .runtime
    static let entity = Entity.WireID.thread

    private(set) var asked: [FaultKind] = []

    private let lock: NSLock = .init()

    var askedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked.count
    }

    init() {}

    func fault(_ kind: FaultKind, _ out: inout Readings) {
        lock.lock()
        asked.append(kind)
        lock.unlock()
        out.put(.detail("stack"))
    }
}

private extension Runtime {
    var memory: Recorder? {
        instance(FakeMemory.self)?.recorder
    }

    var detector: FakeDetector? {
        instance(FakeDetector.self)
    }

    var contributor: FakeContributor? {
        instance(FakeContributor.self)
    }
}

private let faultPair: [Registration] = [
    .stream(FakeDetector.self), .fault(FakeContributor.self),
]

private func request(
    _ id: UInt64,
    instruments: [String],
    atLaunch: Bool = false,
    expiresIn seconds: TimeInterval = 600,
    token: String? = "request-token"
) -> BassetRequest {
    BassetRequest(
        requestId: id,
        instruments: instruments,
        atLaunch: atLaunch,
        expiresAt: Date().addingTimeInterval(seconds),
        maxFrames: nil,
        requestToken: token
    )
}

private func cappedRequest(
    _ id: UInt64,
    instruments: [String],
    maxFrames: UInt32
) -> BassetRequest {
    BassetRequest(
        requestId: id,
        instruments: instruments,
        atLaunch: false,
        expiresAt: Date().addingTimeInterval(600),
        maxFrames: maxFrames,
        requestToken: "request-token"
    )
}

private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "basset-tests-\(UUID().uuidString)")!
}

private func runtime(
    _ instruments: [Registration] = [.stream(FakeMemory.self)],
    opener: RecordingOpener = RecordingOpener()
) -> (Runtime, RecordingOpener) {
    (
        Runtime(
            instruments: instruments,
            opener: opener,
            atLaunchRequests: AtLaunchRequests(storage: scratchDefaults())
        ),
        opener
    )
}

private let bothFakes: [Registration] = [
    .stream(FakeMemory.self),
    .stream(FakeThermal.self),
]

struct RuntimeConvergenceTests {
    @Test func aRequestInTheResponseStartsWhatItNames() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )

        #expect(subject.liveRequestIds == [1])
        #expect(subject.activeInstruments == [.memoryFootprint])
        #expect(subject.memory?.observeCount == 1)
        #expect(
            opener.stream(1) == nil,
            "nothing has been read yet, so nothing is dialled"
        )

        subject.memory?.take()
        subject.settle()
        #expect(opener.stream(1)?.count == 1, "the first reading is what opens it")
    }

    @Test func aRequestMissingFromTheResponseStops() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()
        subject.converge(to: [], ingestEndpoint: "in")

        #expect(subject.liveRequestIds.isEmpty)
        #expect(subject.activeInstruments.isEmpty)
        #expect(subject.memory?.stopCount == 1)
        #expect(opener.stream(1)?.closed == true)
    }

    @Test func anInstrumentStoppedAndStartedAgainReportsEachCallOnce() {
        let (subject, opener) = runtime([.stream(FakeHooked.self)])

        subject.converge(
            to: [request(1, instruments: ["uikit.view.layoutPass"])], ingestEndpoint: "in"
        )
        HookedSubject().work()
        subject.settle()
        #expect(opener.stream(1)?.count == 1)

        subject.converge(to: [], ingestEndpoint: "in")
        subject.converge(
            to: [request(2, instruments: ["uikit.view.layoutPass"])], ingestEndpoint: "in"
        )
        HookedSubject().work()
        subject.settle()

        #expect(
            opener.stream(2)?.count == 1,
            "the second activation reports the call once rather than once per activation"
        )
    }

    @Test func aFaultReachesTheInstrumentsTheRequestAlsoNamed() {
        let (subject, opener) = runtime(faultPair)

        subject.converge(
            to: [
                request(
                    1,
                    instruments: ["concurrency.mainThreadHang", "runtime.threadSnapshot"]
                ),
            ],
            ingestEndpoint: "in"
        )
        subject.detector?.detect()
        subject.settle()

        #expect(subject.contributor?.askedCount == 1)
        #expect(opener.stream(1)?.count == 1, "the contributor's reading was delivered")
    }

    /// The request named the detector alone, so that is all it gets. An
    /// instrument it did not name does not run because another one fired.
    @Test func aFaultDoesNotActivateAnInstrumentTheRequestLeftOut() {
        let (subject, opener) = runtime(faultPair)

        subject.converge(
            to: [request(1, instruments: ["concurrency.mainThreadHang"])],
            ingestEndpoint: "in"
        )
        subject.detector?.detect()
        subject.settle()

        #expect(subject.contributor == nil, "an unnamed instrument was never built")
        #expect(opener.stream(1) == nil, "nothing was read, so nothing was dialled")
    }

    @Test func aFaultRaisedAfterTheInstrumentStoppedIsIgnored() {
        let (subject, _) = runtime(faultPair)

        subject.converge(
            to: [
                request(
                    1,
                    instruments: ["concurrency.mainThreadHang", "runtime.threadSnapshot"]
                ),
            ],
            ingestEndpoint: "in"
        )
        let detector = subject.detector
        subject.converge(to: [], ingestEndpoint: "in")
        detector?.detect()
        subject.settle()

        #expect(subject.contributor?.askedCount == 0)
    }

    /// A request stops itself. Without that, one the control plane never withdrew
    /// — nobody cancelled it, or the device stopped being able to reach it — keeps
    /// its hooks hot for the life of the process.
    @Test func anExpiredRequestStopsItsInstrumentsWithoutBeingTold() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 60)],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()
        #expect(subject.activeInstruments == [.memoryFootprint])

        subject.expire(at: Date().addingTimeInterval(120))

        #expect(subject.liveRequestIds.isEmpty)
        #expect(subject.activeInstruments.isEmpty)
        #expect(subject.memory?.stopCount == 1)
        #expect(opener.stream(1)?.closed == true)
    }

    // Nobody calls anything here. The runtime schedules its own wake-up when
    // the request arrives, which is the half of the promise a test driving
    // `expire(at:)` by hand cannot show.
    @Test func theDeviceWakesItselfWhenTheRequestRunsOut() async throws {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 0.3)],
            ingestEndpoint: "in"
        )
        #expect(subject.activeInstruments == [.memoryFootprint])

        try await Task.sleep(for: .milliseconds(900))
        subject.settle()

        #expect(subject.liveRequestIds.isEmpty)
        #expect(subject.activeInstruments.isEmpty)
        #expect(subject.memory?.stopCount == 1)
    }

    @Test func aRequestStillWithinItsTimeIsLeftRunning() {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 600)],
            ingestEndpoint: "in"
        )
        subject.expire(at: Date().addingTimeInterval(60))

        #expect(subject.liveRequestIds == [1])
        #expect(subject.activeInstruments == [.memoryFootprint])
    }

    @Test func oneRequestExpiringLeavesTheOtherRunning() {
        let (subject, _) = runtime(bothFakes)

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"], expiresIn: 30),
                request(2, instruments: ["power.thermalState"], expiresIn: 600),
            ],
            ingestEndpoint: "in"
        )
        subject.expire(at: Date().addingTimeInterval(60))

        #expect(subject.liveRequestIds == [2])
        #expect(subject.activeInstruments == [.thermalState])
    }

    /// The cap the request asked for, enforced where the readings are taken.
    /// Leaving it to ingest means the device pays for every frame it then has
    /// refused, and a device that cannot reach ingest is never refused at all.
    @Test func aRequestThatHasSentItsLastReadingStops() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [cappedRequest(1, instruments: ["memory.footprint"], maxFrames: 2)],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 2)
        #expect(
            subject.liveRequestIds.isEmpty,
            "the cap was reached, so the request is over"
        )
        #expect(subject.activeInstruments.isEmpty)
        #expect(opener.stream(1)?.closed == true)
    }

    @Test func aRequestUnderItsCapKeepsReading() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [cappedRequest(1, instruments: ["memory.footprint"], maxFrames: 5)],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 1)
        #expect(subject.activeInstruments == [.memoryFootprint])
    }

    /// Every identity below this one restarts at zero when the process does, so
    /// a capture spanning a relaunch needs the launch itself named on each
    /// reading. Inferring the boundary from what is nearby is what merges two
    /// runs into one timeline neither of them had.
    @Test func everyReadingNamesTheRunItCameFrom() throws {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.memory?.take()
        subject.settle()

        // Read as bytes rather than decoded: the decoder is not in the device
        // library these tests link, and the question here is whether the
        // component reached the wire at all.
        var stamp = Data()
        stamp
            .append(contentsOf: withUnsafeBytes(of: Component.WireID.launchId.rawValue
                    .littleEndian)
            {
                Array($0)
            })
        stamp.append(Scalar.uint64.rawValue)
        stamp
            .append(contentsOf: withUnsafeBytes(of: LaunchIdentity.current.littleEndian) {
                Array($0)
            })

        let frames = try #require(opener.stream(1)?.sent)
        #expect(frames.count == 2)
        for frame in frames {
            #expect(frame.range(of: stamp) != nil, "the reading does not name its launch")
        }
    }

    @Test func anInstrumentTwoRequestsWantIsStartedOnce() {
        let (subject, _) = runtime()

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(2, instruments: ["memory.footprint"]),
            ],
            ingestEndpoint: "in"
        )

        #expect(
            subject.memory?.observeCount == 1,
            "one instrument, however many requests name it"
        )
        #expect(subject.liveRequestIds == [1, 2])
    }

    @Test func oneRequestEndingLeavesTheOtherRunning() {
        let (subject, _) = runtime()

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(2, instruments: ["memory.footprint"]),
            ],
            ingestEndpoint: "in"
        )
        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )

        #expect(subject.activeInstruments == [.memoryFootprint])
        #expect(
            subject.memory?.stopCount == 0,
            "the surviving request still wants these readings"
        )
    }

    @Test func areadingReachesEveryRequestThatAskedForIt() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(2, instruments: ["memory.footprint"]),
            ],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 1)
        #expect(opener.stream(2)?.count == 1)
    }

    @Test func areadingSkipsRequestsThatDidNotAskForThatInstrument() {
        let (subject, opener) = runtime(bothFakes)

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(2, instruments: ["power.thermalState"]),
            ],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 1)
        #expect(
            opener.stream(2) == nil,
            "a request whose instrument never emits opens no connection"
        )
    }

    @Test func convergingIsIdempotent() {
        let (subject, _) = runtime()
        let desired = [request(1, instruments: ["memory.footprint"])]

        subject.converge(to: desired, ingestEndpoint: "in")
        subject.converge(to: desired, ingestEndpoint: "in")
        subject.converge(to: desired, ingestEndpoint: "in")

        #expect(subject.memory?.observeCount == 1)
        #expect(subject.memory?.stopCount == 0)
        #expect(subject.liveRequestIds == [1])
    }

    @Test func anInstrumentThisSdkDoesNotKnowIsIgnoredRatherThanFatal() {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint", "from.a.newer.sdk"])],
            ingestEndpoint: "in"
        )

        #expect(subject.activeInstruments == [.memoryFootprint])
        #expect(subject.liveRequestIds == [1])
    }
}

/// The device cannot say whether ingest read what it wrote, so what it reports
/// is what it handed to a stream.
struct DeviceStateTests {
    @Test func framesAreCountedPerRequest() {
        let (subject, _) = runtime(bothFakes)

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(2, instruments: ["power.thermalState"]),
            ],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.memory?.take()
        subject.settle()

        let states = subject.requestStates()
        #expect(states.map(\.requestId) == [1, 2])
        #expect(states[0].framesSent == 2)
        #expect(states[1].framesSent == 0, "this request never asked for that instrument")
    }

    @Test func aReadingWaitingForATokenIsHeldRatherThanCountedAsSent() {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(
                1,
                instruments: ["memory.footprint"],
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        subject.memory?.take()
        subject.settle()

        #expect(subject.requestStates().first?.framesSent == 0)
        #expect(subject.requestStates().first?.framesHeld == 1)

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], atLaunch: true)],
            ingestEndpoint: "in"
        )

        #expect(
            subject.requestStates().first?.framesSent == 1,
            "the launch reading left on flush"
        )
        #expect(subject.requestStates().first?.framesHeld == 0)
    }

    @Test func theStateNamesWhichTransportIsCarryingTheRequest() {
        let (subject, _) = runtime(opener: RecordingOpener(kind: .http2))

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        #expect(
            subject.requestStates().first?.transport == nil,
            "nothing is carrying it yet"
        )

        subject.memory?.take()
        subject.settle()

        #expect(subject.requestStates().first?.transport == .http2)
        #expect(subject.requestStates().first?.transportIsReady == true)
    }

    @Test func aRequestComingBackAfterCancellationCountsFromZero() {
        let (subject, _) = runtime()
        let desired = [request(1, instruments: ["memory.footprint"])]

        subject.converge(to: desired, ingestEndpoint: "in")
        subject.memory?.take()
        subject.settle()
        subject.converge(to: [], ingestEndpoint: "in")
        subject.converge(to: desired, ingestEndpoint: "in")

        #expect(subject.requestStates().first?.framesSent == 0)
    }

    /// ingest refuses a request that has reached max_frames — `429` on the h2
    /// path, `STOP_SENDING` on QUIC.
    @Test func readingsStopBeingWrittenOnceIngestRefusesTheRequest() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()

        opener.stream(1)?.refuse()
        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 1, "nothing is written after the refusal")
        #expect(subject.bufferedFrameCount == 0, "a refusal is not a reason to hold")
        #expect(subject.requestStates().first?.refused == "max_frames")
    }

    /// max_frames is per request, so one request reaching its cap must not
    /// silence an instrument another request is still paying for.
    @Test func oneRefusedRequestDoesNotStopAnother() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(2, instruments: ["memory.footprint"]),
            ],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()
        opener.stream(1)?.refuse()
        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 1, "only what was sent before the refusal")
        #expect(
            opener.stream(2)?.count == 2,
            "the other request still wants these readings"
        )
        #expect(
            subject.activeInstruments == [.memoryFootprint],
            "the instrument keeps running"
        )
    }

    /// What a transport could not deliver reaches the state the device reports,
    /// because a capture that does not know what it lost is misleading rather
    /// than merely incomplete.
    @Test func whatATransportLostIsReported() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()

        opener.stream(1)?.dropped = 7

        #expect(subject.requestStates().first?.framesDropped == 7)
    }

    /// The launch buffer is bounded, and reaching that bound is a loss like any
    /// other — a request cancelled while the device was offline must not grow
    /// memory, but nor should what it discarded vanish from the account.
    @Test func evictingFromTheLaunchBufferCounts() {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(
                1,
                instruments: ["memory.footprint"],
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        for _ in 0 ..< 1030 {
            subject.memory?.take()
        }
        subject.settle()

        let state = subject.requestStates().first
        #expect(state?.framesHeld == 1024, "the bound holds")
        #expect((state?.framesDropped ?? 0) >= 6, "and what it pushed out is counted")
    }

    @Test func activeInstrumentsAreNamedTheWayARequestNamesThem() {
        let (subject, _) = runtime(bothFakes)

        subject.converge(
            to: [request(1, instruments: ["power.thermalState"])],
            ingestEndpoint: "in"
        )

        #expect(subject.activeInstrumentNames() == ["power.thermalState"])
    }
}

struct LaunchBufferTests {
    @Test func readingsTakenBeforeATokenExistsAreHeld() {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(
                1,
                instruments: ["memory.footprint"],
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        subject.memory?.take()
        subject.memory?.take()
        subject.settle()

        #expect(subject.bufferedFrameCount == 2, "no token yet, so nothing may be sent")
    }

    @Test func heldReadingsFlushWhenTheRequestComesBackWithAToken() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(
                1,
                instruments: ["memory.footprint"],
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        subject.memory?.take()
        subject.settle()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], atLaunch: true)],
            ingestEndpoint: "in"
        )

        #expect(subject.bufferedFrameCount == 0)
        #expect(
            opener.stream(1)?.count == 1,
            "the launch reading survives the round trip"
        )
    }

    @Test func heldReadingsAreDroppedWhenTheRequestIsGone() {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(
                1,
                instruments: ["memory.footprint"],
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        subject.memory?.take()
        subject.settle()

        subject.converge(to: [], ingestEndpoint: "in")

        #expect(subject.bufferedFrameCount == 0, "cancelled while offline means discard")
    }

    @Test func launchActivationReadsWhatTheLastResponseLeftBehind() {
        let atLaunchRequests = AtLaunchRequests(storage: scratchDefaults())
        atLaunchRequests.save([request(
            1,
            instruments: ["memory.footprint"],
            atLaunch: true
        )])

        let subject = Runtime(
            instruments: [.stream(FakeMemory.self)],
            opener: RecordingOpener(),
            atLaunchRequests: atLaunchRequests
        )

        subject.startFromDisk()

        #expect(
            subject.activeInstruments == [.memoryFootprint],
            "collecting before any network call"
        )
        #expect(subject.memory?.observeCount == 1)
    }
}
