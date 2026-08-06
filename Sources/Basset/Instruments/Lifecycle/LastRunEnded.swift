import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
    static let id: InstrumentWireID = .lastRunEnded
    static let entity = Entity.WireID.appExit

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
        record.appState = .foreground
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
