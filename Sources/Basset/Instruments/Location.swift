import BassetECS
import Foundation
import ObjectiveC

/// Catches a delegate missing `didUpdateLocations:` by swizzling the class, never a proxy.
final class DelegateSilence: StreamingInstrument, LoadTimeInstall {
    private struct State {
        var startedAt: MonotonicTime?
        var delivered: UInt64 = 0
        var followed: [Int] = []
    }

    static let id: InstrumentID = .locationSilence
    static let entity = Entity.ID.locationDelegate

    static let managerClassName = "CLLocationManager"
    static let setDelegate: Selector = .init("setDelegate:")
    static let startUpdating: Selector = .init("startUpdatingLocation")
    static let didUpdate: Selector = .init("locationManager:didUpdateLocations:")

    private let clock: Clock = .init()
    private let guarded: Mutex<State> = .init(State())

    init() {}

    /// At load: no public API enumerates live `CLLocationManager` instances afterwards.
    static func installAtLoad(_ hooks: HookTable) {
        guard let manager = objc_getClass(managerClassName) as? AnyClass else {
            return
        }

        hooks.catchDelegateClass(at: setDelegate, on: manager)
    }

    /// Reported as a class, not the metre value, so it doesn't read as a position.
    private static func accuracy(of manager: AnyObject) -> String {
        let selector = Selector(("desiredAccuracy"))
        guard manager.responds(to: selector),
              let raw = manager.value(forKey: "desiredAccuracy") as? Double
        else {
            return "unknown"
        }

        return switch raw {
        case ..<0: "best"
        case ..<10: "nearestTenMetres"
        case ..<100: "hundredMetres"
        case ..<1000: "kilometre"
        default: "threeKilometres"
        }
    }

    func observe(_ context: Context) {
        guard let manager = objc_getClass(Self.managerClassName) as? AnyClass else {
            context.emit { out in
                out.put(.callbackImplemented(false))
                out.put(.mechanismStatus("unavailable: this app does not use location"))
            }
            return
        }

        _ = context.swizzle.after(manager, Self.startUpdating) { [weak self] receiver in
            self?.began(receiver, context)
        }

        let classes = context.registries.delegates(ObjectIdentifier(manager))
        let token = classes.attachAndFollow { [weak self] delegateClass in
            self?.watch(delegateClass, context)
        }
        guarded.withLock { $0.followed.append(token) }
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
    }

    private func began(_ receiver: AnyObject, _ context: Context) {
        let now = clock.now()
        guarded.withLock {
            $0.startedAt = now
            $0.delivered = 0
        }
        context.emit { out in
            out.put(.callbackImplemented(true))
            out.put(.accuracyClass(Self.accuracy(of: receiver)))
            out.put(.mechanismStatus("updates requested"))
        }
    }

    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        guard class_getInstanceMethod(delegateClass, Self.didUpdate) != nil else {
            context.emit { out in
                out.put(.callbackImplemented(false))
                out.put(.delegateClass(NSStringFromClass(delegateClass)))
                out.put(
                    .mechanismStatus(
                        "the delegate does not implement locationManager:didUpdateLocations:"
                    )
                )
            }
            return
        }

        // Locations array never read, only shape-matched — it must never leave the device.
        _ = context.swizzle.after(delegateClass, Self.didUpdate, takingTwoObjects: ()) {
            [weak self] _, _, _ in
            self?.updated(delegateClass, context)
        }
    }

    /// Only the first delivery after a start is timed; later ones are just counted.
    private func updated(_ delegateClass: AnyClass, _ context: Context) {
        let (waited, count) = guarded.withLock { state -> (UInt64?, UInt64) in
            state.delivered += 1
            guard let startedAt = state.startedAt else {
                return (nil, state.delivered)
            }

            state.startedAt = nil
            return (clock.now().nanoseconds &- startedAt.nanoseconds, state.delivered)
        }

        context.emit { out in
            out.put(.callbackImplemented(true))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.callbackCount(count))
            if let waited {
                out.put(.silenceNanoseconds(waited))
            }
        }
    }
}
