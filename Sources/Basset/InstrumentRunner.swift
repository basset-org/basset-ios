import BassetECS
import Foundation

protocol Transport: AnyObject, Sendable {
    var kind: TransportType? { get }
    var isReady: Bool { get }
    var note: String? { get }
    var refused: String? { get }
    /// Readings taken but not delivered. Reported rather than dropped silently.
    var dropped: Int { get }
    func send(_ frame: Data)
    func close()
}

extension Transport {
    var kind: TransportType? {
        nil
    }

    var isReady: Bool {
        true
    }

    var note: String? {
        nil
    }

    var refused: String? {
        nil
    }

    var dropped: Int {
        0
    }
}

protocol TransportOpener: Sendable {
    func open(request: BassetRequest, ingestEndpoint: String) -> Transport?
}

struct FaultContributor {
    let instrument: any FaultInstrument
    let context: Context
}

final class InstrumentRunner: @unchecked Sendable {
    private let registrations: [Registration]
    private let byName: [String: Registration]
    private let opener: TransportOpener
    private let atLaunchRequests: AtLaunchRequests
    private let encoder: FrameEncoder = .init()
    private let queue: DispatchQueue = .init(
        label: QueueLabel.instrumentRunner,
        qos: .utility
    )

    /// Per-instrument serial queues over this pool, so one slow instrument can't starve the rest.
    private let flushPool: DispatchQueue = .init(
        label: QueueLabel.instrumentRunnerFlush,
        qos: .utility,
        attributes: .concurrent
    )

    /// `.userInitiated`: a deferred expiry runs instruments past their request, not just late.
    private let expiryQueue: DispatchQueue = .init(
        label: QueueLabel.instrumentRunnerExpiry,
        qos: .userInitiated
    )

    /// Its observers must outlive every activation, so nothing ever releases them.
    private let loadTimeSwizzle: Swizzle = .init()
    private let registries: Registries = .init()

    private var live: [UInt64: BassetRequest] = [:]
    private var transports: [UInt64: Transport] = [:]
    private var active: Set<InstrumentID> = []
    private var instances: [InstrumentID: any Instrument] = [:]
    private let faultLock: NSLock = .init()
    private var faultContributors: [FaultContributor] = []
    private var contexts: [InstrumentID: Context] = [:]
    private var statuses: [InstrumentID: AtomicStatus] = [:]
    private var sent: [UInt64: Int] = [:]
    private var evicted: [UInt64: Int] = [:]
    private var endpoint: String?

    private var buffered: [(requestId: UInt64, frame: Data)] = []
    private let maxBuffered = 1024
    private var expiryTimer: DispatchSourceTimer?

    /// Injectable: a deferred system wake can't be arranged by a test waiting on it.
    private let now: @Sendable () -> Date

    var liveRequestIds: Set<UInt64> {
        queue.sync { Set(live.keys) }
    }

    var activeInstruments: Set<InstrumentID> {
        queue.sync { active }
    }

    var bufferedFrameCount: Int {
        queue.sync { buffered.count }
    }

    init(
        instruments: [Registration] = Instruments.all,
        opener: TransportOpener,
        atLaunchRequests: AtLaunchRequests = AtLaunchRequests(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registrations = instruments
        self.byName = Dictionary(instruments.map { ($0.name, $0) }) { first, _ in first }
        self.opener = opener
        self.atLaunchRequests = atLaunchRequests
        self.now = now
        installLoadTimeHooks()
    }

    func startFromDisk(at moment: Date = Date()) {
        converge(
            to: atLaunchRequests.load(at: moment),
            ingestEndpoint: nil,
            persisting: false
        )
    }

    func converge(
        to desired: [BassetRequest],
        ingestEndpoint: String?,
        persisting: Bool = true
    ) {
        queue.sync {
            // Deduplicated: a response naming a request twice must not trap the app.
            var incoming = [UInt64: BassetRequest]()
            var firstPerRequestId = [BassetRequest]()
            for request in desired where incoming[request.requestId] == nil {
                incoming[request.requestId] = request
                firstPerRequestId.append(request)
            }

            // Snapshotted: `drop` mutates `live`, which a live keys view is a window onto.
            for requestId in Array(live.keys) where incoming[requestId] == nil {
                drop(requestId)
            }

            endpoint = ingestEndpoint ?? endpoint
            for (requestId, request) in incoming {
                live[requestId] = request
                if buffered.contains(where: { $0.requestId == requestId }) {
                    _ = transport(for: requestId, request)
                }
            }

            convergeInstruments()
            scheduleExpiry()

            if persisting {
                atLaunchRequests.save(firstPerRequestId)
            }

            dropRequestsAtTheirCap()
        }
    }

    /// The device expires its own requests rather than waiting on a withdrawal that may never come.
    func expire(at moment: Date = Date()) {
        queue.sync { expireLocked(at: moment) }
    }

    func settle() {
        queue.sync {}
    }

    func requestStates() -> [RequestState] {
        queue.sync {
            live.values
                .sorted { $0.requestId < $1.requestId }
                .map { request in
                    let transport = transports[request.requestId]
                    return RequestState(
                        requestId: request.requestId,
                        instruments: request.instruments,
                        atLaunch: request.atLaunch,
                        expiresAt: request.expiresAt,
                        maxFrames: request.maxFrames,
                        framesSent: sent[request.requestId] ?? 0,
                        framesHeld: buffered.filter { $0.requestId == request.requestId }
                            .count,
                        framesDropped: (evicted[request.requestId] ?? 0)
                            + (transport?.dropped ?? 0),
                        transport: transport?.kind,
                        transportIsReady: transport?.isReady ?? false,
                        transportNote: transport?.note,
                        refused: transport?.refused
                    )
                }
        }
    }

    func activeInstrumentNames() -> [String] {
        queue.sync {
            registrations.filter { active.contains($0.id) }.map(\.name)
        }
    }

    func instance<I: Instrument>(_ type: I.Type) -> I? {
        queue.sync { instances[I.id] as? I }
    }

    /// Contributors are copied on `queue` first: a fault can arrive on any thread.
    func fault(_ kind: FaultKind, from source: AtomicStatus) {
        // Shared with `deactivate`, so a deactivation waits out a fault already in flight.
        faultLock.lock()
        defer { faultLock.unlock() }

        // Re-checked: a fault queued on this lock must not land on the activation that replaced it.
        guard source.isActive else {
            return
        }

        for contributor in faultContributors {
            var readings = contributor.context.readings()
            contributor.instrument.fault(kind, &readings)
            contributor.context.deliver(readings)
        }
    }

    private func installLoadTimeHooks() {
        let hooks = HookTable(swizzle: loadTimeSwizzle, registries: registries)
        for registration in registrations where registration.isAvailableHere {
            registration.installAtLoad?(hooks)
        }
    }

    private func drop(_ requestId: UInt64) {
        transports.removeValue(forKey: requestId)?.close()
        live.removeValue(forKey: requestId)
        sent.removeValue(forKey: requestId)
        evicted.removeValue(forKey: requestId)
        buffered.removeAll { $0.requestId == requestId }
    }

    /// False on the reading path: rebuilding the timer there would push its own deadline out.
    private func expireLocked(at moment: Date, rescheduling: Bool = true) {
        let elapsed = Array(live.filter { !$0.value.isLive(at: moment) }.keys)
        guard !elapsed.isEmpty else {
            if rescheduling {
                scheduleExpiry()
            }

            return
        }

        elapsed.forEach(drop)
        finishDropping()
    }

    private func framesLeft(for requestId: UInt64, _ request: BassetRequest) -> Int {
        guard let cap = request.maxFrames else {
            return .max
        }

        return max(0, Int(cap) - sent[requestId, default: 0])
    }

    /// Enforced on-device rather than left to ingest's refusal, which a device may never hear.
    private func dropRequestsAtTheirCap() {
        let full = Array(live.filter { requestId, request in
            framesLeft(for: requestId, request) == 0
        }
        .keys)
        guard !full.isEmpty else {
            return
        }

        full.forEach(drop)
        finishDropping()
    }

    private func finishDropping() {
        convergeInstruments()
        atLaunchRequests.save(Array(live.values))
        scheduleExpiry()
    }

    /// One wake at the earliest request's expiry, rather than a poll running the whole capture.
    private func scheduleExpiry() {
        expiryTimer?.cancel()
        expiryTimer = nil

        guard let earliest = live.values.map(\.expiresAt).min() else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: expiryQueue)
        timer.schedule(deadline: .now() + max(0, earliest.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            self.queue.async { self.expireLocked(at: self.now()) }
        }
        timer.activate()
        expiryTimer = timer
    }

    private func convergeInstruments() {
        var wanted = [InstrumentID: Registration]()
        for request in live.values {
            for name in request.instruments {
                guard let registration = byName[name],
                      registration.isAvailableHere
                else {
                    continue
                }

                wanted[registration.id] = registration
            }
        }

        for id in active.subtracting(wanted.keys) {
            deactivate(id)
        }
        for (id, registration) in wanted where !active.contains(id) {
            activate(registration)
        }
        active = Set(wanted.keys).intersection(instances.keys)
        faultLock.withLock { rememberFaultContributors() }
    }

    private func activate(_ registration: Registration) {
        let id = registration.id

        let status = statuses[id] ?? AtomicStatus()
        statuses[id] = status

        let instrument = instances[id] ?? registration.build()
        instances[id] = instrument

        // Its own hook table handle, so deactivating releases only this instrument's observers.
        let context = contexts[id] ?? Context(
            instrumentName: registration.name,
            defaultEntity: registration.entity,
            status: status,
            swizzle: Swizzle(),
            registries: registries,
            timerQueue: DispatchQueue(
                label: QueueLabel.flush(instrument: registration.name),
                qos: .utility,
                target: flushPool
            ),
            tallySlots: registration.tallySlots,
            // Its own status, so a reading is never attributed to whatever request replaced it.
            sink: { [weak self, status] entity in
                self?.emit(entity, from: registration, activation: status)
            },
            raise: { [weak self] kind, source in self?.fault(kind, from: source) }
        )
        contexts[id] = context

        status.activate()

        // Gated on the registration: `threadSnapshot` also implements `reading`.
        if registration.delivery == .reading,
           let snapshot = instrument as? any SnapshotInstrument
        {
            var readings = context.readings()
            snapshot.reading(&readings)
            context.deliver(readings)
        }
        if let streaming = instrument as? any StreamingInstrument {
            streaming.observe(context)
        }
    }

    private func rememberFaultContributors() {
        var contributors = [FaultContributor]()
        for id in active {
            guard let instrument = instances[id] as? any FaultInstrument,
                  let context = contexts[id]
            else {
                continue
            }

            contributors.append(FaultContributor(
                instrument: instrument,
                context: context
            ))
        }

        faultContributors = contributors
    }

    /// Drops rather than reuses the instrument: reuse let stale callbacks land in the next capture.
    private func deactivate(_ id: InstrumentID) {
        // Ordered against fault delivery: an in-flight fault finishes against the live instrument.
        faultLock.lock()
        defer { faultLock.unlock() }

        statuses[id]?.deactivate()
        contexts[id]?.teardown()
        if let streaming = instances[id] as? any StreamingInstrument {
            streaming.stopObserving()
        }

        statuses.removeValue(forKey: id)
        contexts.removeValue(forKey: id)
        instances.removeValue(forKey: id)
        rememberFaultContributors()
    }

    private func emit(
        _ entity: Entity,
        from registration: Registration,
        activation: AtomicStatus
    ) {
        var record = entity
        record.add(.instrument(registration.id.rawValue))
        // Rides every reading, not just one, so a capture spanning a relaunch stays attributable.
        record.add(.launchId(LaunchIdentity.current))

        // Refused before framing: sent, an oversized payload is discarded whole at the far end.
        let payload = encoder.encode(record)
        let frame: Data? =
            if UInt64(payload.count) <= FrameReader.maxFrameLength {
                encoder.frame(payload)
            } else {
                nil
            }

        queue.async { [self] in
            // Enforced here too: a deferred wake costs one reading, not an unbounded capture.
            expireLocked(at: now(), rescheduling: false)

            guard activation.isActive else {
                return
            }

            for (requestId, request) in live
                where request.instruments.contains(registration.name)
            {
                guard let frame else {
                    evicted[requestId, default: 0] += 1
                    continue
                }
                guard let transport = transport(for: requestId, request) else {
                    hold(frame, for: requestId)
                    continue
                }

                // A cap the request asked for, not a fault; `refused` says it happened.
                guard transport.refused == nil,
                      framesLeft(for: requestId, request) > 0
                else {
                    continue
                }

                transport.send(frame)
                sent[requestId, default: 0] += 1
            }
            dropRequestsAtTheirCap()
        }
    }

    private func transport(for requestId: UInt64,
                           _ request: BassetRequest) -> Transport?
    {
        if let existing = transports[requestId] {
            return existing
        }
        guard let endpoint,
              let opened = opener.open(request: request, ingestEndpoint: endpoint)
        else {
            return nil
        }

        transports[requestId] = opened
        flushBuffer(for: requestId, request, over: opened)
        return opened
    }

    private func hold(_ frame: Data, for requestId: UInt64) {
        if buffered.count >= maxBuffered {
            let evictedFrame = buffered.removeFirst()
            evicted[evictedFrame.requestId, default: 0] += 1
        }
        buffered.append((requestId: requestId, frame: frame))
    }

    private func flushBuffer(for requestId: UInt64,
                             _ request: BassetRequest,
                             over transport: Transport)
    {
        let waiting = buffered.filter { $0.requestId == requestId }
        buffered.removeAll { $0.requestId == requestId }

        let allowed = waiting.prefix(framesLeft(for: requestId, request))
        allowed.forEach { transport.send($0.frame) }
        sent[requestId, default: 0] += allowed.count
    }
}
