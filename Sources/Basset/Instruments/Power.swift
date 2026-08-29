import BassetEntityComponent
import Foundation

final class ThermalState: Streamable, PlainInstrument {
    static let id: InstrumentID = .thermalState

    private var observer: NSObjectProtocol?

    init() {}

    private static func reading() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    func observe(_ context: Context) {
        report(into: context)
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.report(into: context)
        }
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func report(into context: Context) {
        context.emit(.thermal) { out in
            out.put(.thermalState(Self.reading()))
        }
    }
}
