import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Without this, backgrounded silence looks like nothing happened; emitted only on change.
final class AppState: Streamable, PlainInstrument {
    static let id: InstrumentID = .appStateChanges
    static let entity = Entity.ID.appLifecycle

    private var observers: [NSObjectProtocol] = []
    private let leftForegroundAt: Mutex<MonotonicTime?> = .init(nil)

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        // Current state, not what a background-launch capture would mislabel as foreground.
        report(ApplicationPresence.state, context: context)

        watch(UIApplication.didEnterBackgroundNotification, context) { [weak self] in
            self?.leftForegroundAt.withLock { $0 = context.clock.continuous() }
            self?.report("background", context: context)
        }
        watch(UIApplication.willEnterForegroundNotification, context) { [weak self] in
            self?.report("foreground", context: context)
        }
        // Distinguishes a genuine gap in readings from the app having simply been backgrounded.
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

/// Jetsam/watchdog kill via `SIGKILL`, no handler — written before death, read back next launch.
final class LastRunEnded: Streamable, PlainInstrument {
    static let id: InstrumentID = .lastRunEnded
    static let entity = Entity.ID.appExit

    private static let stampInterval: TimeInterval = 1

    /// Build included — a TestFlight update can bump only `CFBundleVersion`. Truncated to what
    /// `RunRecord` can actually store, or a longer live value would never compare equal to it.
    fileprivate static var appVersion: String {
        let bundle = Bundle.main
        let short = bundle
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard !short.isEmpty else {
            return ""
        }

        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let combined = build.isEmpty ? short : "\(short)+\(build)"
        return String(
            decoding: combined.utf8.prefix(RunRecord.appVersionCapacity),
            as: UTF8.self
        )
    }

    fileprivate static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    fileprivate static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// `kern.boottime` — differs from the last run's own copy only if the device rebooted since.
    fileprivate static var bootTimeMicroseconds: UInt64 {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &boottime, &size, nil, 0) == 0 else {
            return 0
        }

        return UInt64(boottime.tv_sec) * 1000000 + UInt64(boottime.tv_usec)
    }

    private let heartbeat: MainRunLoopHeartbeat = .init()
    private let clock: Clock = .init()
    /// Locked: the stamper thread, pressure handler and notification blocks all reach it.
    private let file: Mutex<RunRecordFile?> = .init(nil)
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

        self.file.withLock { $0 = file }

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
        file.withLock { $0 = nil }
    }

    private func opening() -> RunRecord {
        var record = RunRecord()
        record.launchId = LaunchIdentity.current
        record.startedAtMicroseconds = Entity.microsecondsSinceEpoch()
        record.recordedAtMicroseconds = record.startedAtMicroseconds
        record.appState = ApplicationPresence.isForeground ? .foreground : .background
        record.appVersion = Self.appVersion
        record.osVersion = Self.osVersion
        record.isSimulator = Self.isSimulator
        record.bootTimeMicroseconds = Self.bootTimeMicroseconds
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
                let (limit, overflowed) = previous.memoryUsedBytes
                    .addingReportingOverflow(previous.memoryAvailableBytes)
                if !overflowed {
                    out.put(.memoryLimitBytes(limit))
                }
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
            self?.file.withLock { $0?.stamp { $0.appState = .background } }
        }
        watch(UIApplication.willEnterForegroundNotification) { [weak self] in
            self?.file.withLock { $0?.stamp { $0.appState = .foreground } }
        }
        // The one ending iOS announces; rare — a suspended app is usually reclaimed without it.
        watch(UIApplication.willTerminateNotification) { [weak self] in
            self?.file.withLock { $0?.stamp { $0.cleanExit = true } }
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

    /// A dedicated thread, not a shared queue — a stuck worker stops stamping just when needed.
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

        file.withLock {
            $0?.stamp { record in
                record.recordedAtMicroseconds = Entity.microsecondsSinceEpoch()
                record.mainUnresponsiveNanoseconds = unresponsive
                record.debuggerAttached = Debugger.isAttached
                guard let ledger else {
                    return
                }

                record.memoryUsedBytes = ledger.usedBytes
                record.memoryAvailableBytes = ledger.availableBytes ?? 0
            }
        }
    }

    /// Own pressure source, not a read from `memory.pressure` — this record stays complete alone.
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
            self.file.withLock {
                $0?.stamp { record in
                    record.pressureLevel = level
                    record.pressureRecordedAtMicroseconds = Entity.microsecondsSinceEpoch()
                }
            }
        }
        source.activate()
        pressure = source
    }
}

/// Can't name a signal without a crash handler — EXC_BAD_ACCESS etc. collapse into `unexpected`.
struct RunEnding: Equatable {
    /// 5s: under iOS's own watchdog window (5-20s) — this run ended because of the stall.
    static let watchdogThreshold: UInt64 = 5000000000

    /// Not zero — the last stamp is up to a second stale; hard allocation covers more than that.
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

        // A corrupt record can carry a garbage stamp; refuse the duration rather than trap.
        let elapsed = record.recordedAtMicroseconds - record.startedAtMicroseconds
        let (nanoseconds, overflowed) = elapsed.multipliedReportingOverflow(by: 1000)
        return overflowed ? nil : nanoseconds
    }

    init(
        _ record: RunRecord,
        currentBootTimeMicroseconds: UInt64 = LastRunEnded.bootTimeMicroseconds,
        currentAppVersion: String = LastRunEnded.appVersion,
        currentOSVersion: String = LastRunEnded.osVersion
    ) {
        self.record = record
        state =
            switch record.appState {
            case .foreground: "foreground"
            case .background: "background"
            case .unknown: "unknown"
            }
        reason = Self.reason(
            for: record,
            currentBootTimeMicroseconds: currentBootTimeMicroseconds,
            currentAppVersion: currentAppVersion,
            currentOSVersion: currentOSVersion
        )
    }

    /// Ordered by specificity, not frequency — a stuck main thread outranks low headroom.
    private static func reason(
        for record: RunRecord,
        currentBootTimeMicroseconds: UInt64,
        currentAppVersion: String,
        currentOSVersion: String
    ) -> String {
        if record.cleanExit {
            return "clean"
        }
        // Zero means the field predates this run or its sysctl failed; not a same-boot claim.
        if record.bootTimeMicroseconds > 0, currentBootTimeMicroseconds > 0,
           record.bootTimeMicroseconds != currentBootTimeMicroseconds
        {
            return "reboot"
        }
        if record.debuggerAttached {
            return "debuggerAttached"
        }
        // An empty current version means Bundle.main had none to read, not that every prior
        // version differs from it.
        if !record.appVersion.isEmpty, !currentAppVersion.isEmpty,
           record.appVersion != currentAppVersion
        {
            return "appUpdated"
        }
        if !record.osVersion.isEmpty, record.osVersion != currentOSVersion {
            return "osUpdated"
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
        // Xcode's Stop button sends SIGKILL directly — no watchdog or jetsam involved.
        if record.isSimulator, record.appState == .foreground {
            return "simulatorStopped"
        }
        // Backgrounded apps stop routinely and silently; nothing routine ends a foreground run.
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
