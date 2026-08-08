import BassetECS
import Foundation

protocol Transport: AnyObject, Sendable {
    var kind: TransportType? { get }
    var isReady: Bool { get }
    var note: String? { get }
    var refused: String? { get }
    /// Readings this transport took and could not deliver. A diagnostics tool
    /// that loses them quietly reports absence as "nothing happened", which is
    /// the one thing it cannot afford to say wrongly.
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

    /// Flushes run one instrument at a time but not one *process* at a time. On
    /// one shared serial queue the slowest instrument sets the interval for all
    /// of them: `swiftui.runtimeIssues` enumerating `OSLogStore` starves
    /// one-second timers into arriving six to thirteen seconds apart, so every
    /// rate in the capture is wrong and every count stale when it is read.
    ///
    /// Each instrument gets its own serial queue targeting this pool, which keeps
    /// one instrument's flushes ordered and non-overlapping while letting a slow
    /// one wait on its own.
    private let flushPool: DispatchQueue = .init(
        label: QueueLabel.instrumentRunnerFlush,
        qos: .utility,
        attributes: .concurrent
    )

    /// Expiry does not share the flush pool. `.utility` is right for flushes —
    /// a slow instrument should wait rather than starve the others — but it is
    /// the class the system defers first when a process is backgrounded,
    /// throttled, or saving power, which is most of a capture's life on a
    /// phone. A deferred flush costs freshness; a deferred expiry keeps
    /// instruments running after the request that authorised them ran out.
    private let expiryQueue: DispatchQueue = .init(
        label: QueueLabel.instrumentRunnerExpiry,
        qos: .userInitiated
    )

    /// The load-time handle. Its observers are the ones that must outlive every
    /// activation — a chokepoint that stops registering births cannot be caught
    /// up later — so nothing ever releases them.
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
        atLaunchRequests: AtLaunchRequests = AtLaunchRequests()
    ) {
        self.registrations = instruments
        self.byName = Dictionary(instruments.map { ($0.name, $0) }) { first, _ in first }
        self.opener = opener
        self.atLaunchRequests = atLaunchRequests
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
            // One id cannot describe two captures, and keying the pairs
            // directly traps: a response that names a request twice would take
            // the app down rather than the request.
            var incoming = [UInt64: BassetRequest]()
            var firstPerRequestId = [BassetRequest]()
            for request in desired where incoming[request.requestId] == nil {
                incoming[request.requestId] = request
                firstPerRequestId.append(request)
            }

            // Snapshot the ids: dropping mutates `live`, and a keys view is a
            // window onto the dictionary being changed underneath it.
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

    /// The device stops its own instruments. A request the control plane never
    /// withdraws — nobody cancelled it, or this device has not been able to reach
    /// the control plane since — expires anyway, which is the difference between
    /// a bounded capture and a battery complaint.
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

    /// Every active instrument with something to add gets asked, including the
    /// one that raised it if it also contributes. Synchronous, because the
    /// state worth reading is the one the caller is standing in.
    ///
    /// A fault arrives on whichever thread noticed it — the hang watchdog runs
    /// on its own — while every dictionary here is written from `queue`. Reading
    /// one from that thread is a data race on a Swift dictionary, which
    /// terminates the app the SDK is a guest in. The contributors are copied on
    /// the queue instead, so this path touches no dictionary at all.
    func fault(_ kind: FaultKind, from source: AtomicStatus) {
        // Held across delivery, and taken by `deactivate` too. Reading the list
        // and then asking each contributor leaves a gap in between, and a
        // request ending inside it means a stopped instrument still does the
        // work — `runtime.threadSnapshot` suspends every thread in the process
        // to answer, which is not something to do on behalf of a capture that
        // has already finished.
        //
        // The cost is that a deactivation waits for a fault already being
        // captured. That is the right way round: the capture is bounded and the
        // request it belongs to is still live when it starts.
        faultLock.lock()
        defer { faultLock.unlock() }

        // Checked again here, against the activation that raised it. `Context`
        // checks once on the caller's thread, and a fault that then waits on
        // this lock through its own request's deactivation would otherwise be
        // delivered to whatever activation replaced it — a hang from a finished
        // capture, recorded as if the new request had seen it.
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

    /// `rescheduling` is false on the reading path. Rebuilding the timer costs
    /// a cancel and a create, and a capture emitting faster than its own expiry
    /// would push the deadline out on every reading — the wake would never
    /// arrive, which is the failure this check exists to cover for. Dropping
    /// still reschedules, through `finishDropping`.
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

    /// Every reading the request asked for has been delivered, so there is
    /// nothing left for it to observe. Enforced here rather than left to ingest
    /// refusing: a refusal arrives after the device has already paid for the
    /// capture, and a device that cannot reach ingest never hears one at all.
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

    /// One wake-up, at the moment the earliest request runs out, rather than a
    /// poll that keeps the process busy for the whole capture and beyond it.
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

            self.queue.async { self.expireLocked(at: Date()) }
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

        // Its own handle on the process-wide hook table, so deactivating this
        // instrument releases this instrument's observers and nobody else's.
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
            // The status this activation owns, carried into the sink. A reading
            // that passed `deliver`'s check and is still in the air when the
            // request ends would otherwise be sent against whatever is live by
            // the time the queue reaches it — a finished capture's reading,
            // attributed to the request that replaced it.
            sink: { [weak self, status] entity in
                self?.emit(entity, from: registration, activation: status)
            },
            raise: { [weak self] kind, source in self?.fault(kind, from: source) }
        )
        contexts[id] = context

        status.activate()

        // On the registration rather than on a conformance. Asking the instance
        // what it can do let a second conformance decide when readings arrive:
        // `runtime.threadSnapshot` is registered `.fault` and also implemented
        // `reading`, so activating it suspended every thread in the process
        // before anything had gone wrong. Delivery is what the factory accepted,
        // and nothing else gets a vote.
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

    /// Deactivating drops the instrument, its context and its status rather than
    /// keeping them for the next activation.
    ///
    /// Whatever is still in flight holds this context: a queue probe already
    /// submitted, a notification block that entered before `removeObserver`
    /// returned, a log reader's watermark. Keeping them meant the next
    /// activation reused the same objects with the status flipped live again, so
    /// a callback belonging to a finished request landed in the next request's
    /// capture. Dropped, that callback holds a status that stays deactivated for
    /// as long as it lives, and lands nowhere.
    private func deactivate(_ id: InstrumentID) {
        // Ordered against fault delivery rather than racing it: a fault already
        // being captured finishes against the instrument that was live when it
        // started, and one arriving after this returns finds the instrument
        // gone from the list rather than gone from under it.
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
        // Which run of the app this came from. Rides on every reading rather
        // than on one of them, because a capture spanning a relaunch is exactly
        // the case where the boundary cannot be inferred from what is nearby.
        record.add(.launchId(LaunchIdentity.current))
        let frame = encoder.frame(encoder.encode(record))

        queue.async { [self] in
            // The bound is enforced here as well as by the timer, so a wake
            // that the system defers costs one reading's latency rather than an
            // unbounded capture. Before the send loop: a reading produced after
            // its request ran out is one the request no longer authorises.
            expireLocked(at: Date(), rescheduling: false)

            guard activation.isActive else {
                return
            }

            for (requestId, request) in live
                where request.instruments.contains(registration.name)
            {
                guard let transport = transport(for: requestId, request) else {
                    hold(frame, for: requestId)
                    continue
                }

                // Refused rather than lost: max_readings is a cap the request
                // asked for, so what it turns away is not a fault to report as
                // one. `refused` on the state says it happened.
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
