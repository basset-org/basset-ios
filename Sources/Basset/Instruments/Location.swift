import BassetECS
import Foundation
import ObjectiveC

/// The "no callbacks ever arrive" class of location bug, which is the domain's
/// whole reason for existing.
///
/// An app calls `startUpdatingLocation` and waits. Nothing comes back. There is
/// no error, no callback, no log line — Core Location simply never delivers. The
/// two commonest causes are both invisible from inside the app: **the delegate
/// does not implement `locationManager:didUpdateLocations:` at all**, or the
/// delegate is held weakly and went nil while the app still holds the manager.
///
/// **Reached by class-swizzling the delegate, not by proxying it.** Three
/// consequences, and the first is what makes this instrument possible at all:
///
/// - **The absence is free.** `class_getInstanceMethod` returning nil for
///   `locationManager:didUpdateLocations:` *is* the first cause, reported without
///   installing anything. A proxy would have to be asked; a class answers.
/// - **CoreLocation is never linked.** A proxy conforms to
///   `CLLocationManagerDelegate`, which means importing the framework — and
///   location is permission-gated, so linking it would destroy the finding
///   `permissions` depends on: an app that does not link it does not use it.
/// - Nothing is added that the app did not write. `class_addMethod` for a
///   callback the app omitted would change `responds(to:)`, and Core Location
///   consults `responds(to:)` before delivering — so adding one makes the system
///   believe the app handles updates it ignores, turning a diagnosable silence
///   into an undiagnosable one.
///
/// **Nothing here goes on the wire but timing and shape.** No latitude, no
/// longitude, no course, no speed — none of it is read. The accuracy *class* the
/// app asked for is a configuration value, not a position.
final class DelegateSilence: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentID = .locationSilence
    static let entity = Entity.ID.locationDelegate

    static let managerClassName = "CLLocationManager"
    static let setDelegate: Selector = .init("setDelegate:")
    static let startUpdating: Selector = .init("startUpdatingLocation")
    static let didUpdate: Selector = .init("locationManager:didUpdateLocations:")

    private let clock: Clock = .init()
    private let lock: NSLock = .init()
    private var startedAt: MonotonicTime?
    private var delivered: UInt64 = 0
    private var followed: [Int] = []

    init() {}

    /// At load, because a delegate set before the request arrives is one nothing
    /// can name afterwards — no public API enumerates live `CLLocationManager`
    /// instances. Only the class is remembered, so an app that never touches
    /// location pays one failed class lookup.
    static func installAtLoad(_ hooks: HookTable) {
        guard let manager = objc_getClass(managerClassName) as? AnyClass else {
            return
        }

        hooks.catchDelegateClass(at: setDelegate, on: manager)
    }

    /// A configuration value the app chose, never a position. Read through the
    /// runtime so CoreLocation stays unlinked, and reported as a class rather
    /// than a number because the number is metres and metres invite a reader to
    /// think it describes where somebody is.
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
        lock.withLock { followed.append(token) }
    }

    func stopObserving() {
        lock.withLock {
            startedAt = nil
            delivered = 0
            followed.removeAll()
        }
    }

    /// The app asked for updates. What matters is the moment, and the accuracy it
    /// asked for — a manager left at `kCLLocationAccuracyThreeKilometers` indoors
    /// waits a long time for a fix that a reader would otherwise call a hang.
    private func began(_ receiver: AnyObject, _ context: Context) {
        let now = clock.now()
        lock.withLock {
            startedAt = now
            delivered = 0
        }
        context.emit { out in
            out.put(.callbackImplemented(true))
            out.put(.accuracyClass(Self.accuracy(of: receiver)))
            out.put(.mechanismStatus("updates requested"))
        }
    }

    /// Swizzles the app's own delegate class, or reports that there is nothing to
    /// swizzle — which is the finding rather than a failure.
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

        // Two objects: the manager and the array of locations. Neither is read
        // — the array is exactly what must never leave the device — but the
        // shape has to match the selector or the swizzle is refused.
        _ = context.swizzle.after(delegateClass, Self.didUpdate, takingTwoObjects: ()) {
            [weak self] _, _, _ in
            self?.updated(delegateClass, context)
        }
    }

    /// The first delivery after a start is the one worth timing: it is the
    /// interval the user experienced as waiting. Later ones are a cadence, and
    /// counting them is enough.
    private func updated(_ delegateClass: AnyClass, _ context: Context) {
        let waited = lock.withLock { () -> UInt64? in
            delivered += 1
            guard let startedAt else {
                return nil
            }

            self.startedAt = nil
            return clock.now().nanoseconds &- startedAt.nanoseconds
        }
        let count = lock.withLock { delivered }

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
