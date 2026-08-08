import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Ambient context: what the app was doing while everything else was recorded.
/// A reading taken while backgrounded means something different from the same one
/// in the foreground, and the readings that are *missing* mean something too — a
/// suspended app collects nothing, and without this that silence cannot be told
/// from nothing having happened.
///
/// On change, never per reading. App state moves a handful of times an hour
/// against readings that arrive by the second, so it goes on the wire at the
/// highest scope where it is constant.
final class AppState: StreamingInstrument {
    static let id: InstrumentID = .appStateChanges
    static let entity = Entity.ID.appLifecycle

    private var observers: [NSObjectProtocol] = []
    private let leftForegroundAt: Mutex<MonotonicTime?> = .init(nil)

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        // What the app is doing now, not what it would be doing had the request
        // been here at launch. A capture that opens during a background launch
        // is the case this instrument exists to explain, and reporting
        // `foreground` into it mislabels every reading until the next resume.
        report(ApplicationPresence.state, context: context)

        watch(UIApplication.didEnterBackgroundNotification, context) { [weak self] in
            self?.leftForegroundAt.withLock { $0 = context.clock.continuous() }
            self?.report("background", context: context)
        }
        watch(UIApplication.willEnterForegroundNotification, context) { [weak self] in
            self?.report("foreground", context: context)
        }
        // A capture with no readings for four minutes has two explanations
        // and no way to tell them apart. This one says which.
        watch(UIApplication.didBecomeActiveNotification, context) { [weak self] in
            guard let self else {
                return
            }

            let away = leftForegroundAt.withLock { left -> MonotonicTime? in
                defer { left = nil }
                return left
            }
            guard let away else {
                return
            }

            let elapsed = context.clock.continuous().nanoseconds - away.nanoseconds
            context.emit { out in
                out.put(.appState("resumed"))
                out.put(.totalNanoseconds(elapsed))
            }
        }
        #endif
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        leftForegroundAt.withLock { $0 = nil }
    }

    private func watch(
        _ name: Notification.Name,
        _ context: Context,
        _ body: @escaping () -> Void
    ) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                body()
            }
        )
    }

    private func report(_ state: String, context: Context) {
        context.emitIfChanged { out in
            out.put(.appState(state))
        }
    }
}

/// Why the previous run of this app stopped, and what it was holding at the time.
///
/// The deaths worth explaining leave nothing behind: jetsam and the watchdog both
/// arrive as `SIGKILL`, so no handler runs and the process never learns it is
/// ending. This instrument answers by writing down what a death would need to be
/// explained *before* one happens — footprint, headroom, system pressure, how
/// long the main thread has gone without reaching idle — and reading it back at
/// the next launch.
///
/// **It reports the previous run and then watches this one**, which is why it
/// pairs with `at_launch`: armed now, it explains the death that follows. A
/// request that starts after the fact finds whatever the last armed run wrote,
/// and nothing if there was never one.
///
/// The stamp is once a second from a thread of its own. Not a preference — a
/// record refreshed only on app-state changes would carry an hour-old footprint
/// into a verdict about the instant of death, and the whole reading turns on how
/// fresh those numbers are.
final class LastRunEnded: StreamingInstrument {
    static let id: InstrumentID = .lastRunEnded
    static let entity = Entity.ID.appExit

    private static let stampInterval: TimeInterval = 1

    private static var appVersion: String {
        Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private let heartbeat: MainRunLoopHeartbeat = .init()
    private let clock: Clock = .init()
    private var file: RunRecordFile?
    private var stamper: Thread?
    private var pressure: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []

    init() {}

    private static func name(of level: RunRecord.PressureLevel) -> String {
        switch level {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        case .unknown: "unknown"
        }
    }

    func observe(_ context: Context) {
        guard let url = RunRecordFile.url(), let file = RunRecordFile(
            at: url,
            startedBy: opening()
        )
        else {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: no run record could be opened"))
            }
            return
        }

        self.file = file

        report(file.previous, into: context)

        heartbeat.start()
        watchApplicationState()
        watchMemoryPressure()
        startStamping(context)
    }

    func stopObserving() {
        stamper?.cancel()
        stamper = nil
        pressure?.cancel()
        pressure = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        heartbeat.stop()
        file = nil
    }

    private func opening() -> RunRecord {
        var record = RunRecord()
        record.launchId = LaunchIdentity.current
        record.startedAtMicroseconds = Entity.microsecondsSinceEpoch()
        record.recordedAtMicroseconds = record.startedAtMicroseconds
        record.appState = ApplicationPresence.isForeground ? .foreground : .background
        record.appVersion = Self.appVersion
        return record
    }

    private func report(_ previous: RunRecord?, into context: Context) {
        guard let previous else {
            context.emit { out in
                out.put(.mechanismStatus("no previous run was recorded"))
            }
            return
        }

        let ending = RunEnding(previous)
        context.emit { out in
            out.put(.exitReason(ending.reason))
            out.put(.appState(ending.state))
            out.put(.intervalEndMicroseconds(previous.recordedAtMicroseconds))

            if !previous.appVersion.isEmpty {
                out.put(.appVersion(previous.appVersion))
            }
            if let duration = ending.runDurationNanoseconds {
                out.put(.totalNanoseconds(duration))
            }
            if previous.memoryUsedBytes > 0 {
                out.put(.memoryUsedBytes(previous.memoryUsedBytes))
            }
            if previous.memoryAvailableBytes > 0 {
                out.put(.memoryAvailableBytes(previous.memoryAvailableBytes))
                out.put(
                    .memoryLimitBytes(previous.memoryUsedBytes + previous
                        .memoryAvailableBytes)
                )
            }
            if previous.pressureLevel != .unknown {
                out.put(.memoryPressureLevel(Self.name(of: previous.pressureLevel)))
            }
            if previous.mainUnresponsiveNanoseconds > 0 {
                out.put(.hangNanoseconds(previous.mainUnresponsiveNanoseconds))
            }
        }
    }

    private func watchApplicationState() {
        #if canImport(UIKit)
        watch(UIApplication.didEnterBackgroundNotification) { [weak self] in
            self?.file?.stamp { $0.appState = .background }
        }
        watch(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.file?.stamp { $0.appState = .foreground }
        }
        // The one ending iOS announces. It arrives rarely — a suspended app is
        // usually reclaimed without it — so its absence proves nothing and its
        // presence proves everything.
        watch(UIApplication.willTerminateNotification) { [weak self] in
            self?.file?.stamp { $0.cleanExit = true }
        }
        #endif
    }

    private func watch(_ name: Notification.Name, _ body: @escaping () -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                body()
            }
        )
    }

    /// A thread rather than a timer on a shared queue: the reason to keep
    /// stamping is that the process may be about to stop answering, and a queue
    /// whose worker is stuck behind the same problem stops stamping exactly when
    /// the record needs to be fresh.
    private func startStamping(_ context: Context) {
        let stamping = Thread { [weak self] in
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: Self.stampInterval)
                guard context.isActive, let self else {
                    continue
                }

                self.stampOnce()
            }
        }
        stamping.name = QueueLabel.runRecordStamp
        stamping.qualityOfService = .utility
        stamping.start()
        stamper = stamping
    }

    private func stampOnce() {
        let ledger = MemoryLedger.read()
        let beat = heartbeat.read()
        let now = clock.now()
        let unresponsive = beat.awake ? now.nanoseconds &- beat.idleAt.nanoseconds : 0

        file?.stamp { record in
            record.recordedAtMicroseconds = Entity.microsecondsSinceEpoch()
            record.mainUnresponsiveNanoseconds = unresponsive
            guard let ledger else {
                return
            }

            record.memoryUsedBytes = ledger.usedBytes
            record.memoryAvailableBytes = ledger.availableBytes ?? 0
        }
    }

    /// Its own pressure source rather than a reading taken from
    /// `memory.pressure`. An instrument that reached into another one would tie
    /// this reading to whether the request happened to name both, and the whole
    /// point of the record is that it is complete on its own.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [
            .warning,
            .critical,
        ])
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else {
                return
            }

            let level: RunRecord.PressureLevel = source.data.contains(.critical)
                ? .critical
                : .warning
            self.file?.stamp { record in
                record.pressureLevel = level
                record.pressureRecordedAtMicroseconds = Entity.microsecondsSinceEpoch()
            }
        }
        source.activate()
        pressure = source
    }
}

/// How a run ended, read out of what it managed to write down before it stopped.
///
/// Every verdict here is an inference, and the reading says so by carrying the
/// evidence beside it — the footprint, the headroom, how long the main thread had
/// been unresponsive — rather than only the conclusion. A reader that disagrees
/// with the rule can see what the rule was applied to.
///
/// What this cannot do is name a signal. `EXC_BAD_ACCESS`, an illegal instruction
/// and an uncaught exception are one verdict here, `unexpected`: separating them
/// needs a crash handler, which is the most hazardous mechanism in the catalog.
/// Every app already ships a crash reporter, and none of them answer the rest of
/// this list.
struct RunEnding: Equatable {
    /// Five seconds of a main thread that never reached idle. iOS's own watchdog
    /// fires between roughly five and twenty seconds depending on the transition,
    /// so this is under the floor rather than at the average: a run that ends
    /// while the main thread has been stuck this long ended *because* it was.
    static let watchdogThreshold: UInt64 = 5000000000

    /// Jetsam takes the process at the limit, so the last stamp before it lands
    /// shows the headroom nearly gone. Not zero: the stamp is up to a second old,
    /// and an app allocating hard covers more than nothing in that second.
    static let exhaustedHeadroomBytes: UInt64 = 16 * 1024 * 1024

    /// Pressure this old is not what killed the process, whatever else is true.
    static let pressureRelevanceMicroseconds: UInt64 = 30000000

    let reason: String
    let state: String
    let record: RunRecord

    var runDurationNanoseconds: UInt64? {
        guard record.recordedAtMicroseconds > record.startedAtMicroseconds
        else {
            return nil
        }

        return (record.recordedAtMicroseconds - record.startedAtMicroseconds) * 1000
    }

    init(_ record: RunRecord) {
        self.record = record
        state =
            switch record.appState {
            case .foreground: "foreground"
            case .background: "background"
            case .unknown: "unknown"
            }
        reason = Self.reason(for: record)
    }

    /// Ordered by how specific the evidence is, not by how common the ending is.
    /// A stuck main thread is a narrower fact than low headroom, and low headroom
    /// is narrower than the system being under pressure — so a run that shows two
    /// of them is named after the one that says most.
    private static func reason(for record: RunRecord) -> String {
        if record.cleanExit {
            return "clean"
        }
        if record.mainUnresponsiveNanoseconds >= watchdogThreshold {
            return "watchdog"
        }
        if record.memoryAvailableBytes > 0,
           record.memoryAvailableBytes < exhaustedHeadroomBytes
        {
            return "ownMemoryLimit"
        }
        if record.pressureLevel == .critical, pressureWasCurrent(in: record) {
            return "systemMemoryPressure"
        }
        // A backgrounded app that simply stops is the ordinary case: iOS reclaims
        // suspended processes constantly and tells nobody. In the foreground it is
        // the opposite — the user was looking at it, and nothing routine ends a
        // run there.
        return record.appState == .background ? "reclaimedWhileBackgrounded" : "unexpected"
    }

    private static func pressureWasCurrent(in record: RunRecord) -> Bool {
        guard record.recordedAtMicroseconds >= record.pressureRecordedAtMicroseconds
        else {
            return false
        }

        let age = record.recordedAtMicroseconds - record.pressureRecordedAtMicroseconds
        return age <= pressureRelevanceMicroseconds
    }
}
