import BassetEntityComponent
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
    let instrument: any Faultable
    let context: Context
}

final class InstrumentRunner: @unchecked Sendable {
    private let registrations: [Registration]
    private let byName: [String: Registration]
    private let opener: TransportOpener
    private let atLaunchRequests: AtLaunchRequests
    private let backlogDirectory: URL
    private let encoder: FrameEncoder = .init()
    /// `.userInitiated` for the same reason as the flush pool below: a desired-state push
    /// converges with a `sync` onto this queue, behind every emit already queued, and at
    /// `utility` that wait was measured at seven seconds on a saturated phone.
    private let queue: DispatchQueue = .init(
        label: QueueLabel.instrumentRunner,
        qos: .userInitiated
    )

    /// Per-instrument serial queues over this pool, so one slow instrument can't starve the rest.
    /// `.userInitiated`, not `.utility`: on a two-core phone saturated by the app's own
    /// user-initiated work, utility got no time for eleven seconds at a stretch while the
    /// camera delivered 628 frames and the sampler took 214 stacks, and the readings that
    /// should explain such a stretch are the ones that go missing. The work here is a few
    /// milliseconds a second; the band matters, not the cost.
    private let flushPool: DispatchQueue = .init(
        label: QueueLabel.instrumentRunnerFlush,
        qos: .userInitiated,
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
    /// What each active instrument was actually built with — absent means no config sent.
    private var activeConfig: [InstrumentID: Data] = [:]
    private var instances: [InstrumentID: any Instrument] = [:]
    private let faultLock: NSLock = .init()
    private var faultContributors: [FaultContributor] = []
    private var contexts: [InstrumentID: Context] = [:]
    private var statuses: [InstrumentID: AtomicStatus] = [:]
    private var sent: [UInt64: Int] = [:]
    private var evicted: [UInt64: Int] = [:]
    private var endpoint: String?

    private var buffered: [(requestId: UInt64, frame: Data)] = []
    /// Per request, not per launch: an image sent to one capture is absent from another.
    private var reportedImages: [UInt64: Set<String>] = [:]
    /// Requests whose set changed before anything was open to tell.
    private var owesActiveSet: Set<UInt64> = []
    /// Images a request needs before its held readings mean anything, kept out of the backlog:
    /// evicting one would leave it marked as reported and every address in it unplaceable.
    private var owedImages: [UInt64: [BinaryImage]] = [:]
    private let maxBuffered = 1024
    /// Naturally bounded by the images a process maps, but per request and under backpressure
    /// that is still a number worth stating. Dropping one costs nothing lasting: an image is
    /// only marked as reported once it is sent, so the next address in it owes it again.
    private let maxOwedImages = 64
    private var expiryTimer: DispatchSourceTimer?

    /// Injectable: a deferred system wake can't be arranged by a test waiting on it.
    private let now: @Sendable () -> Date

    var liveRequestIds: Set<UInt64> {
        queue.sync { Set(live.keys) }
    }

    var activeInstruments: Set<InstrumentID> {
        queue.sync { active }
    }

    /// What this device would run if a request named every instrument in the catalog —
    /// each one's own probe against `registries`, not what is actually live right now.
    var defaultRelevantInstruments: Set<InstrumentID> {
        queue.sync {
            Set(registrations
                .filter { $0.isAvailableHere && $0.relevance(registries) == .relevant }
                .map(\.id))
        }
    }

    var bufferedFrameCount: Int {
        queue.sync { buffered.count }
    }

    init(
        instruments: [Registration] = Instruments.all,
        opener: TransportOpener,
        atLaunchRequests: AtLaunchRequests = AtLaunchRequests(),
        backlogDirectory: URL = PersistedBacklog.defaultDirectory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registrations = instruments
        self.byName = Dictionary(instruments.map { ($0.name, $0) }) { first, _ in first }
        self.opener = opener
        self.atLaunchRequests = atLaunchRequests
        self.backlogDirectory = backlogDirectory
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

            // Only once the control plane has spoken: the disk-only bootstrap list is a
            // cache of `atLaunch` requests, not proof that everything else is really gone.
            if ingestEndpoint != nil {
                PersistedBacklog.sweep(keeping: Set(incoming.keys), in: backlogDirectory)
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

    #if DEBUG
    /// A transport is kept per request, so a machine attaching or leaving after one
    /// is open would otherwise keep sending down the path chosen before it changed.
    func forgetTransports() {
        queue.sync {
            transports.values.forEach { $0.close() }
            transports.removeAll()
        }
    }
    #endif

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
    func fault(_ kind: FaultKind, id: UInt32, from source: AtomicStatus) {
        // Shared with `deactivate`, so a deactivation waits out a fault already in flight.
        faultLock.lock()
        defer { faultLock.unlock() }

        // Re-checked: a fault queued on this lock must not land on the activation that replaced it.
        guard source.isActive else {
            return
        }

        for contributor in faultContributors {
            var readings = contributor.instrument.fault(kind)
            if !readings.isEmpty {
                readings.tagEveryEntity(with: .faultId(id))
            }
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
        reportedImages.removeValue(forKey: requestId)
        owesActiveSet.remove(requestId)
        owedImages.removeValue(forKey: requestId)
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
        let before = active
        var wanted = [InstrumentID: Registration]()
        var configData = [InstrumentID: Data]()
        // Ascending by requestId, so the highest wins — `live` promises no order of its own.
        for request in live.values.sorted(by: { $0.requestId < $1.requestId }) {
            for name in request.instruments {
                guard let registration = byName[name],
                      registration.isAvailableHere
                else {
                    continue
                }

                wanted[registration.id] = registration
                if let data = request.instrumentConfig[name] {
                    configData[registration.id] = data
                }
            }
        }

        for id in active.subtracting(wanted.keys) {
            deactivate(id)
        }
        // A running instrument does not pick up a changed config on its own; restart it.
        for id in active.intersection(wanted.keys) where activeConfig[id] != configData[id] {
            deactivate(id)
            active.remove(id)
        }
        defer {
            if !before.isEmpty, active != before {
                emitActiveSet()
            }
        }
        for (id, registration) in wanted where !active.contains(id) {
            activeConfig[id] = configData[id]
            activate(registration, config: configData[id])
        }
        active = Set(wanted.keys).intersection(instances.keys)
        faultLock.withLock { rememberFaultContributors() }
    }

    private func activate(_ registration: Registration, config: Data?) {
        let id = registration.id

        let status = statuses[id] ?? AtomicStatus()
        statuses[id] = status

        let (instrument, configRefused) = instances[id].map { ($0, false) }
            ?? registration.build(config)
        instances[id] = instrument

        // Its own hook table handle, so deactivating releases only this instrument's observers.
        let context = contexts[id] ?? Context(
            status: status,
            swizzle: Swizzle(),
            registries: registries,
            timerQueue: DispatchQueue(
                label: QueueLabel.flush(instrument: registration.name),
                qos: .userInitiated,
                target: flushPool
            ),
            tallySlots: registration.tallySlots,
            // Its own status, so a reading is never attributed to whatever request replaced it.
            sink: { [weak self, status] entity in
                self?.emit(
                    entity,
                    instrumentId: registration.id,
                    matchingRequestsNaming: registration.name,
                    activation: status
                )
            },
            raise: { [weak self] kind, id, source in self?.fault(kind, id: id, from: source) }
        )
        contexts[id] = context

        status.activate()
        if configRefused {
            emitConfigRefused(for: registration, activation: status)
        }

        // Gated on the registration: `threadSnapshot` also implements `reading`.
        if registration.delivery == .reading,
           let snapshot = instrument as? any Snapshotable
        {
            context.deliver(snapshot.reading())
        }
        if let streaming = instrument as? any Streamable {
            streaming.observe(context)
        }
    }

    /// Bypasses `Instrument`: the trigger is another instrument's own config decode failing.
    private func emitConfigRefused(for registration: Registration, activation: AtomicStatus) {
        let entity = Entity(
            .instrumentConfig,
            components: [.instrument(registration.id.rawValue)]
        )
        emit(
            entity,
            instrumentId: .configRefused,
            matchingRequestsNaming: registration.name,
            activation: activation
        )
    }

    private func rememberFaultContributors() {
        var contributors = [FaultContributor]()
        for id in active {
            guard let instrument = instances[id] as? any Faultable,
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
        if let streaming = instances[id] as? any Streamable {
            streaming.stopObserving()
        }

        statuses.removeValue(forKey: id)
        contexts.removeValue(forKey: id)
        instances.removeValue(forKey: id)
        activeConfig.removeValue(forKey: id)
        rememberFaultContributors()
    }

    private func emit(
        _ entity: Entity,
        instrumentId: InstrumentID,
        matchingRequestsNaming filterName: String,
        activation: AtomicStatus
    ) {
        let record = Entity(
            id: entity.id,
            capturedAt: entity.capturedAt,
            components: entity.components + [
                .instrument(instrumentId.rawValue),
                // Rides every reading, not just one, so a capture spanning a relaunch stays
                // attributable.
                .launchId(LaunchIdentity.current),
            ]
        )

        // Refused before framing: sent, an oversized payload is discarded whole at the far end.
        let payload = encoder.encode(record)
        let frame: Data? =
            if UInt64(payload.count) <= FrameReader.maxFrameLength {
                encoder.frame(payload)
            } else {
                nil
            }

        // Only walked when a reading actually names addresses: `covering` reads every mapped
        // image, which no reading without frames should pay for.
        let addresses: [UInt64] = record.components.compactMap { component in
            guard component.known == .frameAddress,
                  case .uint64(let address) = component.value
            else {
                return nil
            }

            return address
        }

        queue.async { [self] in
            // Walked here rather than on the thread that emitted: an instrument reporting from
            // the main thread must not pay for reading every mapped image.
            let placing = addresses.isEmpty ? [] : BinaryImages.covering(addresses)

            // Enforced here too: a deferred wake costs one reading, not an unbounded capture.
            expireLocked(at: now(), rescheduling: false)

            guard activation.isActive else {
                return
            }

            for (requestId, request) in live
                where request.instruments.contains(filterName)
            {
                guard let frame else {
                    evicted[requestId, default: 0] += 1
                    continue
                }
                guard let transport = transport(for: requestId, request) else {
                    // Owed, not held: the backlog is capped and counted, and an image that
                    // fell out of it would leave every address in this reading unplaceable.
                    owe(placing, for: requestId)
                    hold(frame, for: requestId)
                    continue
                }

                for image in imageFrames(placing, into: requestId) {
                    guard transport.refused == nil else {
                        break
                    }

                    transport.send(image)
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

    /// What each live request is running, now that it changed. Without it a capture spanning
    /// an update cannot tell an instrument that was quiet from one that was not yet on.
    private func emitActiveSet(only wanted: UInt64? = nil) {
        let running = active
        for (requestId, request) in live where wanted == nil || wanted == requestId {
            let named = request.instruments.compactMap { byName[$0]?.id }
            let mine = named.filter { running.contains($0) }.sorted { $0.rawValue < $1.rawValue }
            guard !mine.isEmpty else {
                continue
            }

            var components: [Component] = [
                .instrument(InstrumentID.instrumentsActive.rawValue),
                .launchId(LaunchIdentity.current),
                .occurrenceCount(UInt64(mine.count)),
            ]
            // Repeated, innermost order irrelevant — the set is what matters, not a sequence.
            for id in mine {
                components.append(.instrument(id.rawValue))
            }
            let record = Entity(.activeInstruments, components: components)

            let payload = encoder.encode(record)
            guard UInt64(payload.count) <= FrameReader.maxFrameLength else {
                continue
            }

            // Owed rather than held: the backlog is for readings, and a marker queued in it
            // would take a reading's place. Sent the moment this request opens a transport.
            let frame = encoder.frame(payload)
            guard let transport = transports[requestId] else {
                owesActiveSet.insert(requestId)
                continue
            }
            guard transport.refused == nil else {
                continue
            }

            // Uncounted, like the images: saying what a capture is running is not a reading
            // the request asked for, and a small cap must not be spent describing itself.
            transport.send(frame)
        }
    }

    /// An address is unreadable without the image holding it, and each capture is read on
    /// its own — so every request needs its own copy, once.
    /// Not counted against the request's cap: max_readings bounds what a device was asked
    /// for, and an address the reader cannot place is not one of them.
    private func owe(_ images: [BinaryImage], for requestId: UInt64) {
        var already = Set((owedImages[requestId] ?? []).map(\.uuid))
        for image in images where already.insert(image.uuid).inserted {
            guard owedImages[requestId, default: []].count < maxOwedImages else {
                return
            }

            owedImages[requestId, default: []].append(image)
        }
    }

    private func imageFrames(
        _ images: [BinaryImage],
        into requestId: UInt64
    ) -> [Data] {
        var frames = [Data]()
        for image in images where !reportedImages[requestId, default: []].contains(image.uuid) {
            let record = Entity(.binaryImage, components: [
                .imageName(image.name),
                .imageLoadAddress(image.loadAddress),
                .imageUUID(image.uuid),
                .imageTextBytes(image.size),
                .launchId(LaunchIdentity.current),
            ])

            let payload = encoder.encode(record)
            guard UInt64(payload.count) <= FrameReader.maxFrameLength else {
                continue
            }

            reportedImages[requestId, default: []].insert(image.uuid)
            frames.append(encoder.frame(payload))
        }
        return frames
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
        // Ahead of the backlog: a reading flushed before its image arrives is unreadable
        // for as long as anyone looks at it.
        for frame in imageFrames(
            owedImages.removeValue(forKey: requestId) ?? [],
            into: requestId
        ) {
            opened.send(frame)
        }

        if owesActiveSet.remove(requestId) != nil {
            emitActiveSet(only: requestId)
        }

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
