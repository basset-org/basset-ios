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
    private var refusals: Int

    init(kind: TransportType? = .quic, refusingFirst refusals: Int = 0) {
        self.kind = kind
        self.refusals = refusals
    }

    func open(request: BassetRequest, ingestEndpoint: String) -> Transport? {
        lock.lock()
        defer { lock.unlock() }
        guard refusals == 0 else {
            refusals -= 1
            return nil
        }

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

/// State lives on the instance, not a process-global, reached through the runtime.
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

    /// A reading past the read ceiling, built from the widest string the format carries.
    func takeOversized() {
        lock.lock()
        let context = self.context
        lock.unlock()

        let widest = String(repeating: "x", count: 255)
        let enough = Int(FrameReader.maxFrameLength) / widest.utf8.count + 1
        context?.emit { out in
            for _ in 0 ..< enough {
                out.put(.detail(widest))
            }
        }
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
    static let id: InstrumentID = .memoryFootprint
    static let name = "memory.footprint"
    static let domain: Domain = .memory
    static let entity = Entity.ID.process

    let recorder: Recorder = .init()

    init() {}
}

private final class FakeThermal: FakeInstrument {
    static let id: InstrumentID = .thermalState
    static let name = "power.thermalState"
    static let domain: Domain = .power
    static let entity = Entity.ID.thermal

    let recorder: Recorder = .init()

    init() {}
}

/// A hooked class, not a recorder — the runtime reuses a deactivated context.
@objc private class HookedSubject: NSObject {
    @objc dynamic func work() {}
}

private final class FakeHooked: StreamingInstrument {
    static let id: InstrumentID = .viewLayoutPass
    static let name = "uikit.view.layoutPass"
    static let domain: Domain = .uikit
    static let entity = Entity.ID.process

    init() {}

    func observe(_ context: Context) {
        _ = context.swizzle
            .after(HookedSubject.self, #selector(HookedSubject.work)) { _ in
                context.emit { out in out.put(.detail("pass")) }
            }
    }

    func stopObserving() {}
}

/// The fault path — one instrument detects, the runtime asks whoever else is active.
private final class FakeDetector: StreamingInstrument, @unchecked Sendable {
    static let id: InstrumentID = .mainThreadHang
    static let name = "concurrency.mainThreadHang"
    static let domain: Domain = .concurrency
    static let entity = Entity.ID.mainThread

    private let lock: NSLock = .init()
    private var context: Context?

    /// The activation's status, so a fault can tell late from live.
    var raisingStatus: AtomicStatus? {
        lock.lock()
        defer { lock.unlock() }
        return context?.status
    }

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
    static let id: InstrumentID = .threadSnapshot
    static let name = "runtime.threadSnapshot"
    static let domain: Domain = .runtime
    static let entity = Entity.ID.thread

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

private extension InstrumentRunner {
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
    instrumentConfig: [String: Data] = [:],
    atLaunch: Bool = false,
    expiresIn seconds: TimeInterval = 600,
    token: String? = "request-token"
) -> BassetRequest {
    BassetRequest(
        requestId: id,
        instruments: instruments,
        instrumentConfig: instrumentConfig,
        atLaunch: atLaunch,
        expiresAt: Date().addingTimeInterval(seconds),
        maxFrames: nil,
        requestToken: token
    )
}

private func cappedRequest(
    _ id: UInt64,
    instruments: [String],
    maxFrames: UInt32,
    atLaunch: Bool = false,
    token: String? = "request-token"
) -> BassetRequest {
    BassetRequest(
        requestId: id,
        instruments: instruments,
        atLaunch: atLaunch,
        expiresAt: Date().addingTimeInterval(600),
        maxFrames: maxFrames,
        requestToken: token
    )
}

/// A clock the test moves, so a deadline can pass while its timer is still pending.
private final class MovableClock: @unchecked Sendable {
    private let lock: NSLock = .init()
    private var reading: Date = .init()

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return reading
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        reading = reading.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "basset-tests-\(UUID().uuidString)")!
}

private func runtime(
    _ instruments: [Registration] = [.stream(FakeMemory.self)],
    opener: RecordingOpener = RecordingOpener(),
    clock: MovableClock? = nil
) -> (InstrumentRunner, RecordingOpener) {
    (
        InstrumentRunner(
            instruments: instruments,
            opener: opener,
            atLaunchRequests: AtLaunchRequests(storage: scratchDefaults()),
            now: clock?.now ?? { Date() }
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
        let memory = subject.memory
        memory?.take()
        subject.settle()
        subject.converge(to: [], ingestEndpoint: "in")

        #expect(subject.liveRequestIds.isEmpty)
        #expect(subject.activeInstruments.isEmpty)
        #expect(memory?.stopCount == 1)
        #expect(opener.stream(1)?.closed == true)
    }

    /// Each restart gets a fresh instance, context and status — nothing carries over.
    @Test func aRestartedInstrumentSharesNothingWithTheRunBefore() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        let first = subject.memory
        subject.converge(to: [], ingestEndpoint: "in")

        subject.converge(
            to: [request(2, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        let second = subject.memory
        #expect(first !== second)

        second?.take()
        first?.take()
        subject.settle()
        #expect(
            opener.stream(2)?.count == 1,
            "the finished activation still holds its own context, and it delivers nowhere"
        )
    }

    /// A fault used to blame a hang on whatever request replaced the one that raised it.
    @Test func aFaultFromAFinishedActivationIsNotRecordedByItsReplacement() throws {
        let (subject, _) = runtime(faultPair)
        let both = ["concurrency.mainThreadHang", "runtime.threadSnapshot"]

        subject.converge(to: [request(1, instruments: both)], ingestEndpoint: "in")
        let finished = try #require(subject.detector?.raisingStatus)

        subject.converge(to: [], ingestEndpoint: "in")
        subject.converge(to: [request(2, instruments: both)], ingestEndpoint: "in")
        subject.settle()
        let replacement = try #require(subject.contributor)

        subject.fault(.hang, from: finished)
        subject.settle()
        #expect(replacement.askedCount == 0, "the request that raised it is over")

        let live = try #require(subject.detector?.raisingStatus)
        subject.fault(.hang, from: live)
        subject.settle()
        #expect(replacement.askedCount == 1, "and a live one is still delivered")
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

    /// The request named the detector alone — an instrument it didn't name doesn't run.
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
        let contributor = subject.contributor
        subject.converge(to: [], ingestEndpoint: "in")
        detector?.detect()
        subject.settle()

        #expect(contributor?.askedCount == 0)
    }

    /// A request stops itself, or an unreachable control plane leaves hooks hot forever.
    @Test func anExpiredRequestStopsItsInstrumentsWithoutBeingTold() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 60)],
            ingestEndpoint: "in"
        )
        let memory = subject.memory
        memory?.take()
        subject.settle()
        #expect(subject.activeInstruments == [.memoryFootprint])

        subject.expire(at: Date().addingTimeInterval(120))

        #expect(subject.liveRequestIds.isEmpty)
        #expect(subject.activeInstruments.isEmpty)
        #expect(memory?.stopCount == 1)
        #expect(opener.stream(1)?.closed == true)
    }

    /// Nothing is called — the runtime wakes itself, unlike expire(at:) by hand.
    @Test func theDeviceWakesItselfWhenTheRequestRunsOut() async {
        let (subject, _) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 0.3)],
            ingestEndpoint: "in"
        )
        #expect(subject.activeInstruments == [.memoryFootprint])
        let memory = subject.memory

        let expired = await eventually { subject.liveRequestIds.isEmpty }
        subject.settle()

        #expect(expired, "the request outlived an expiry set 0.3s out")
        #expect(subject.activeInstruments.isEmpty)
        #expect(memory?.stopCount == 1)
    }

    /// `emit` rechecks the deadline before sending, so a late reading is held, not sent.
    @Test func aReadingTakenAfterADeferredWakeIsNotSent() throws {
        let clock = MovableClock()
        let (subject, opener) = runtime(clock: clock)

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 600)],
            ingestEndpoint: "in"
        )
        let memory = try #require(subject.memory)
        memory.take()
        subject.settle()
        #expect(opener.stream(1)?.count == 1, "still inside its time")

        clock.advance(by: 601)
        memory.take()
        subject.settle()

        #expect(
            opener.stream(1)?.count == 1,
            "the reading was taken after the request ran out"
        )
        #expect(subject.liveRequestIds.isEmpty, "and the request is over")
    }

    /// A stopped instrument's context stays deactivated, so in-flight work lands nowhere.
    @Test func aReadingFromAStoppedInstrumentIsNotSent() throws {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"], expiresIn: 600)],
            ingestEndpoint: "in"
        )
        let memory = try #require(subject.memory)
        let before = opener.stream(1)?.count ?? 0

        subject.expire(at: Date().addingTimeInterval(601))
        #expect(subject.liveRequestIds.isEmpty)

        memory.take()
        subject.settle()

        #expect(opener.stream(1)?.count ?? 0 == before)
        #expect(subject.liveRequestIds.isEmpty)
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

    /// Enforced device-side — leaving it to ingest wastes network on frames it refuses.
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

    /// Other identities restart at zero on relaunch, so each reading names its launch.
    @Test func everyReadingNamesTheRunItCameFrom() throws {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.memory?.take()
        subject.settle()

        // Read as raw bytes — the decoder isn't linked here; only the wire matters.
        var stamp = Data()
        stamp
            .append(contentsOf: withUnsafeBytes(of: Component.ID.launchId.rawValue
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

    @Test func aResponseNamingOneRequestTwiceKeepsTheFirstRatherThanFatal() {
        let (subject, _) = runtime(bothFakes)

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"]),
                request(1, instruments: ["power.thermalState"]),
            ],
            ingestEndpoint: "in"
        )

        #expect(subject.liveRequestIds == [1])
        #expect(subject.activeInstruments == [.memoryFootprint])
        #expect(subject.requestStates().count == 1)
    }

    @Test func aRequestNamedTwiceIsStoredOnceForTheNextLaunch() {
        let atLaunchRequests = AtLaunchRequests(storage: scratchDefaults())
        let subject = InstrumentRunner(
            instruments: bothFakes,
            opener: RecordingOpener(),
            atLaunchRequests: atLaunchRequests
        )

        subject.converge(
            to: [
                request(1, instruments: ["memory.footprint"], atLaunch: true),
                request(1, instruments: ["power.thermalState"], atLaunch: true),
            ],
            ingestEndpoint: "in"
        )

        #expect(atLaunchRequests.load().map(\.instruments) == [["memory.footprint"]])
    }

    @Test func aStoreHoldingTheSameRequestTwiceStillActivatesAtLaunch() {
        let atLaunchRequests = AtLaunchRequests(storage: scratchDefaults())
        let duplicated = request(1, instruments: ["memory.footprint"], atLaunch: true)
        atLaunchRequests.save([duplicated, duplicated])

        let subject = InstrumentRunner(
            instruments: [.stream(FakeMemory.self)],
            opener: RecordingOpener(),
            atLaunchRequests: atLaunchRequests
        )

        subject.startFromDisk()

        #expect(subject.liveRequestIds == [1])
        #expect(subject.memory?.observeCount == 1)
    }
}

/// The device reports what it handed to a stream, not whether ingest read it.
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

    /// ingest refuses a maxed-out request: `429` over h2, `STOP_SENDING` over QUIC.
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

    /// max_frames is per request — one cap must not silence another request's instrument.
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

    /// Transport loss reaches device state — a capture unaware of its loss is misleading.
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

    /// The launch buffer is bounded; eviction counts as loss, not silence.
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

    /// A reader refuses an oversized frame; refusing it here spends none of the network.
    @Test func aReadingTooLargeToBeReadIsRefusedAndCounted() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )
        subject.memory?.takeOversized()
        subject.settle()

        let state = subject.requestStates().first
        #expect(state?.framesSent == 0)
        #expect(state?.framesHeld == 0, "and not held for a later flush either")
        #expect(state?.framesDropped == 1)
        #expect(opener.stream(1) == nil, "nothing was worth dialling for")
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

        let subject = InstrumentRunner(
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

    /// Waiting for a token is not exempt from max_frames — the cap still ends it.
    @Test func aBacklogLargerThanTheCapSendsOnlyWhatTheCapCovers() {
        let atLaunchRequests = AtLaunchRequests(storage: scratchDefaults())
        let opener = RecordingOpener()
        let subject = InstrumentRunner(
            instruments: [.stream(FakeMemory.self)],
            opener: opener,
            atLaunchRequests: atLaunchRequests
        )

        subject.converge(
            to: [cappedRequest(
                1,
                instruments: ["memory.footprint"],
                maxFrames: 3,
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        for _ in 0 ..< 10 {
            subject.memory?.take()
        }
        subject.settle()

        #expect(subject.requestStates().first?.framesHeld == 10)
        #expect(subject.requestStates().first?.framesSent == 0)

        subject.converge(
            to: [cappedRequest(
                1,
                instruments: ["memory.footprint"],
                maxFrames: 3,
                atLaunch: true
            )],
            ingestEndpoint: "in"
        )

        #expect(opener.stream(1)?.count == 3, "the cap, not the backlog")
        #expect(
            subject.liveRequestIds.isEmpty,
            "the flush spent the cap, so the request is over"
        )
        #expect(subject.activeInstruments.isEmpty)
        #expect(opener.stream(1)?.closed == true)
        #expect(subject.bufferedFrameCount == 0)
        #expect(
            atLaunchRequests.load().isEmpty,
            "and it does not come back on the next launch"
        )
    }

    /// A refuse-then-succeed opener puts the flush on the reading path, not owed extra.
    @Test func aReadingThatOpensTheTransportRespectsWhatTheFlushSpent() {
        let (subject, opener) = runtime(opener: RecordingOpener(refusingFirst: 1))

        subject.converge(
            to: [cappedRequest(1, instruments: ["memory.footprint"], maxFrames: 1)],
            ingestEndpoint: "in"
        )
        subject.memory?.take()
        subject.settle()

        #expect(subject.bufferedFrameCount == 1, "the opener refused, so it is held")

        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 1, "the cap, counting the flushed reading")
        #expect(subject.liveRequestIds.isEmpty)
    }

    /// What the flush sent counts against the cap rather than resetting it.
    @Test func aBacklogUnderTheCapLeavesTheRestOfIt() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [cappedRequest(
                1,
                instruments: ["memory.footprint"],
                maxFrames: 3,
                atLaunch: true,
                token: nil
            )],
            ingestEndpoint: nil
        )
        subject.memory?.take()
        subject.memory?.take()
        subject.settle()

        subject.converge(
            to: [cappedRequest(
                1,
                instruments: ["memory.footprint"],
                maxFrames: 3,
                atLaunch: true
            )],
            ingestEndpoint: "in"
        )

        #expect(opener.stream(1)?.count == 2)
        #expect(subject.liveRequestIds == [1], "one reading of the cap is left")

        subject.memory?.take()
        subject.settle()

        #expect(opener.stream(1)?.count == 3)
        #expect(subject.liveRequestIds.isEmpty)
    }
}

/// Serialized — a process-wide probe means two runs would reset each other's readings.
@Suite(.serialized)
struct TallyHandoffTests {
    @Test func theRunnerGivesAnInstrumentTheSlotsItDeclared() {
        SlotProbe.reset()
        let (subject, _) = runtime([.stream(SlotHungry.self)])

        subject.converge(
            to: [request(1, instruments: ["render.frame.pacing"])],
            ingestEndpoint: "in"
        )

        #expect(
            SlotProbe.read() == 42,
            "slot 5 was refused, so the runner handed over fewer than six"
        )
    }

    /// Writes on both sides of the edge — reading tallySlots back would just restate it.
    @Test func anInstrumentTakingTheDefaultIsGivenFourAndNoMore() {
        SlotProbe.reset()
        let (subject, _) = runtime([.stream(SlotDefaulting.self)])

        subject.converge(
            to: [request(1, instruments: ["memory.footprint"])],
            ingestEndpoint: "in"
        )

        #expect(SlotProbe.read(.inRange) == 7, "slot 3 is inside the default four")
        #expect(SlotProbe.read(.pastTheEnd) == 0, "slot 4 is not, and is refused")
    }
}

private struct FakeConfig: Decodable, Sendable, Equatable {
    let thresholdMs: Int
}

private final class FakeConfigurable: ConfigurableStreamingInstrument {
    static let id: InstrumentID = .queueLatency
    static let entity = Entity.ID.dispatchQueue
    static let defaultConfig: FakeConfig = .init(thresholdMs: 250)

    let config: FakeConfig
    let recorder: Recorder = .init()

    init(config: FakeConfig) {
        self.config = config
    }

    func observe(_ context: Context) {
        recorder.observing(context)
    }

    func stopObserving() {
        recorder.stopped()
    }
}

private func configJSON(_ thresholdMs: Int) -> Data {
    Data("{\"thresholdMs\":\(thresholdMs)}".utf8)
}

private let malformedConfigJSON: Data = .init("not json".utf8)

private func sentRefusal(_ transport: RecordingTransport?) -> Bool {
    var stamp = Data([PayloadKind.entity.rawValue])
    stamp.append(contentsOf: withUnsafeBytes(of: Entity.ID.instrumentConfig.rawValue.littleEndian) {
        Array($0)
    })
    return transport?.sent.contains { $0.range(of: stamp) != nil } ?? false
}

struct ConfigurableInstrumentTests {
    @Test func validConfigIsDecodedRatherThanTheDefault() {
        let (subject, opener) = runtime([.stream(FakeConfigurable.self)])

        subject.converge(
            to: [request(
                1,
                instruments: ["concurrency.queue.latency"],
                instrumentConfig: ["concurrency.queue.latency": configJSON(300)]
            )],
            ingestEndpoint: "in"
        )

        #expect(subject.instance(FakeConfigurable.self)?.config == FakeConfig(thresholdMs: 300))
        #expect(!sentRefusal(opener.stream(1)), "nothing was refused")
        #expect(
            subject.instance(FakeConfigurable.self)?.recorder.observeCount == 1,
            "built is not the same as started"
        )
    }

    @Test func noConfigTakesTheDefaultWithoutBeingARefusal() {
        let (subject, opener) = runtime([.stream(FakeConfigurable.self)])

        subject.converge(
            to: [request(1, instruments: ["concurrency.queue.latency"])],
            ingestEndpoint: "in"
        )
        subject.settle()

        #expect(subject.instance(FakeConfigurable.self)?.config == FakeConfigurable.defaultConfig)
        #expect(
            !sentRefusal(opener.stream(1)),
            "an instrument with nothing to configure is the ordinary case, not a refusal"
        )
    }

    @Test func malformedConfigFallsBackToTheDefaultAndReportsItself() {
        let (subject, opener) = runtime([.stream(FakeConfigurable.self)])

        subject.converge(
            to: [request(
                1,
                instruments: ["concurrency.queue.latency"],
                instrumentConfig: ["concurrency.queue.latency": malformedConfigJSON]
            )],
            ingestEndpoint: "in"
        )
        subject.settle()

        #expect(subject.instance(FakeConfigurable.self)?.config == FakeConfigurable.defaultConfig)
        #expect(sentRefusal(opener.stream(1)), "a rejected config is reported, not silent")
    }

    @Test func configSentToAnInstrumentThatTakesNoneIsRefused() {
        let (subject, opener) = runtime()

        subject.converge(
            to: [request(
                1,
                instruments: ["memory.footprint"],
                instrumentConfig: ["memory.footprint": configJSON(300)]
            )],
            ingestEndpoint: "in"
        )
        subject.settle()

        #expect(
            sentRefusal(opener.stream(1)),
            "memory.footprint has no Config type — sending it one is not silently ignored"
        )
    }

    /// `live` is a dictionary; only sorting by request id makes this a rule, not luck.
    @Test func theHighestRequestIdsConfigWinsWhenTwoNameTheSameInstrument() {
        let (subject, _) = runtime([.stream(FakeConfigurable.self)])

        subject.converge(
            to: [
                request(
                    1,
                    instruments: ["concurrency.queue.latency"],
                    instrumentConfig: ["concurrency.queue.latency": configJSON(100)]
                ),
                request(
                    2,
                    instruments: ["concurrency.queue.latency"],
                    instrumentConfig: ["concurrency.queue.latency": configJSON(200)]
                ),
            ],
            ingestEndpoint: "in"
        )

        #expect(subject.instance(FakeConfigurable.self)?.config == FakeConfig(thresholdMs: 200))
    }

    /// An already-running instrument does not keep a config a later convergence dropped.
    @Test func aRequestThatStopsSendingConfigDoesNotOverrideTheOneThatStillDoes() {
        let (subject, _) = runtime([.stream(FakeConfigurable.self)])

        subject.converge(
            to: [
                request(
                    1,
                    instruments: ["concurrency.queue.latency"],
                    instrumentConfig: ["concurrency.queue.latency": configJSON(100)]
                ),
                request(2, instruments: ["concurrency.queue.latency"]),
            ],
            ingestEndpoint: "in"
        )

        #expect(subject.instance(FakeConfigurable.self)?.config == FakeConfig(thresholdMs: 100))
    }

    @Test func aChangedConfigRestartsTheInstrumentRatherThanBeingIgnored() {
        let (subject, _) = runtime([.stream(FakeConfigurable.self)])

        subject.converge(
            to: [request(
                1,
                instruments: ["concurrency.queue.latency"],
                instrumentConfig: ["concurrency.queue.latency": configJSON(100)]
            )],
            ingestEndpoint: "in"
        )
        let first = subject.instance(FakeConfigurable.self)
        #expect(first?.config == FakeConfig(thresholdMs: 100))

        subject.converge(
            to: [request(
                1,
                instruments: ["concurrency.queue.latency"],
                instrumentConfig: ["concurrency.queue.latency": configJSON(200)]
            )],
            ingestEndpoint: "in"
        )
        let second = subject.instance(FakeConfigurable.self)

        #expect(second?.config == FakeConfig(thresholdMs: 200))
        #expect(first !== second, "a running instrument cannot pick up new config in place")
        #expect(first?.recorder.stopCount == 1, "the stale instance was torn down, not leaked")
    }

    @Test func theRefusalReachesOnlyRequestsThatNamedTheRefusedInstrument() {
        let (subject, opener) = runtime([.stream(FakeConfigurable.self), .stream(FakeMemory.self)])

        subject.converge(
            to: [
                request(
                    1,
                    instruments: ["concurrency.queue.latency"],
                    instrumentConfig: ["concurrency.queue.latency": malformedConfigJSON]
                ),
                request(2, instruments: ["memory.footprint"]),
            ],
            ingestEndpoint: "in"
        )
        subject.settle()

        #expect(sentRefusal(opener.stream(1)))
        #expect(
            !sentRefusal(opener.stream(2)),
            "this request never named the instrument whose config was refused"
        )
    }
}

private enum SlotProbe {
    enum Slot: Int {
        case declared
        case inRange
        case pastTheEnd
    }

    private static let values: Mutex<[UInt64]> = .init([0, 0, 0])

    static func reset() {
        values.withLock { $0 = [0, 0, 0] }
    }

    static func record(_ slot: Slot, _ seen: UInt64) {
        values.withLock { $0[slot.rawValue] = seen }
    }

    static func read(_ slot: Slot = .declared) -> UInt64 {
        values.withLock { $0[slot.rawValue] }
    }
}

/// Declares more counters than default and writes the highest, like render.frame.pacing.
private final class SlotHungry: StreamingInstrument {
    static let id: InstrumentID = .framePacing
    static let entity = Entity.ID.displayUpdate
    static let tallySlots = 6

    init() {}

    func observe(_ context: Context) {
        context.hotPath.add(TallySlot(5), 42)
        SlotProbe.record(.declared, context.tally.read(TallySlot(5)))
    }

    func stopObserving() {}
}

/// Declares nothing, so the shared default decides its slot count; writes both sides.
private final class SlotDefaulting: StreamingInstrument {
    static let id: InstrumentID = .memoryFootprint
    static let entity = Entity.ID.process

    init() {}

    func observe(_ context: Context) {
        context.hotPath.add(TallySlot(3), 7)
        context.hotPath.add(TallySlot(4), 9)
        SlotProbe.record(.inRange, context.tally.read(TallySlot(3)))
        SlotProbe.record(.pastTheEnd, context.tally.read(TallySlot(4)))
    }

    func stopObserving() {}
}
