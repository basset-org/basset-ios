import BassetEntityComponent
import Foundation

#if canImport(UIKit)
import UIKit
#endif

final class MemoryFootprint: Streamable, PlainInstrument {
    static let id: InstrumentID = .memoryFootprint

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(1), into: .process) { out, _ in
            MemoryLedger.read()?.write(into: &out)
        }
    }

    func stopObserving() {}
}

/// Watches both the system-wide Mach pressure source and app-scoped didReceiveMemoryWarning.
final class MemoryPressure: Streamable, PlainInstrument {
    static let id: InstrumentID = .memoryPressure

    private var source: DispatchSourceMemoryPressure?
    private var observer: NSObjectProtocol?

    init() {}

    private static func level(of event: DispatchSource.MemoryPressureEvent) -> String {
        if event.contains(.critical) {
            return "critical"
        }
        if event.contains(.warning) {
            return "warning"
        }
        return "normal"
    }

    func observe(_ context: Context) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [
            .normal,
            .warning,
            .critical,
        ])
        source.setEventHandler { [weak self, weak source] in
            guard let source else {
                return
            }

            self?.report(Self.level(of: source.data), scope: "system", context: context)
        }
        source.activate()
        self.source = source

        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.report("warning", scope: "app", context: context)
        }
        #endif
    }

    func stopObserving() {
        source?.cancel()
        source = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    /// Never `emitIfChanged`: each crossing gets its own footprint, even warning-critical-warning.
    private func report(_ level: String, scope: String, context: Context) {
        // Critical only: a thread walk on every warning would cost more than it explains.
        let faultId: UInt32? = level == "critical" ? EntityIdentity.next() : nil

        context.emit(.memoryPressure) { out in
            out.put(.memoryPressureLevel(level))
            out.put(.memoryPressureScope(scope))
            MemoryLedger.read()?.write(into: &out)
            if let faultId {
                out.put(.faultId(faultId))
            }
        }
        if let faultId {
            context.fault(.memoryPressure, faultId)
        }
    }
}
