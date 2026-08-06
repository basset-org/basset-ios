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
    static let id: InstrumentWireID = .appStateChanges
    static let entity = Entity.WireID.appLifecycle

    private var observers: [NSObjectProtocol] = []
    private let lock: NSLock = .init()
    private var leftForegroundAt: MonotonicTime?

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        report("foreground", context: context)

        watch(UIApplication.didEnterBackgroundNotification, context) { [weak self] in
            self?.lock.withLock { self?.leftForegroundAt = context.clock.now() }
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

            let away = self.lock.withLock { () -> MonotonicTime? in
                defer { self.leftForegroundAt = nil }
                return self.leftForegroundAt
            }
            guard let away else {
                return
            }

            let elapsed = context.clock.now().nanoseconds - away.nanoseconds
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
        lock.withLock { leftForegroundAt = nil }
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
