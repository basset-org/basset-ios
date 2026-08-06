import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Every edge of memory pressure, and what the app was holding when it crossed.
///
/// Two mechanisms because they answer two questions. The Mach pressure source
/// reports what the *system* is under, which is what precedes a jetsam kill and
/// arrives whether or not the app is in front. `didReceiveMemoryWarning` reports
/// that iOS asked *this app* to give memory back, which is the moment a developer
/// recognises. A capture holding one without the other reads as if nothing
/// happened on the side that was not watched, so both are here and the reading
/// says which one spoke.
///
/// The ledger is read at the edge rather than on a timer. What is worth knowing
/// is the footprint at the moment iOS complained, and a sample taken a second
/// later is a different app.
final class MemoryPressure: StreamingInstrument {
    static let id: InstrumentWireID = .memoryPressure
    static let entity = Entity.WireID.memoryPressure

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

    /// Never `emitIfChanged`: pressure returning to warning after a spell of
    /// critical is a second crossing, and the footprint attached to it is a
    /// different number from the first one's.
    private func report(_ level: String, scope: String, context: Context) {
        context.emit { out in
            out.put(.memoryPressureLevel(level))
            out.put(.memoryPressureScope(scope))
            MemoryLedger.read()?.write(into: &out)
        }
        // Whatever else the request left active gets to say what the process was
        // doing while it was one step from being killed. Critical only: a warning
        // is common enough that answering every one with a process-wide thread
        // walk would cost more than it explains.
        if level == "critical" {
            context.fault(.memoryPressure)
        }
    }
}
