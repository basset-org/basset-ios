import BassetECS
import Foundation
import ObjectiveC

/// The blank or grey map, which otherwise has no signal anywhere.
///
/// `MKMapView` reports tile loading through two delegate callbacks, and an app
/// that implements neither — which is nearly all of them — gets a grey grid and
/// no indication that anything failed. There is no error to catch, no return
/// value to check, and the map view itself says nothing.
///
/// Both callbacks are void and carry no completion handler, so this **defines**
/// them where the app has none, the same way `webkit` reaches its termination
/// callback. `Swizzle.afterOrDefine` holds the rule for when that is allowed.
///
/// **No coordinates, ever.** No region centre, no span, nothing positional is
/// read — a tile failure is a count and an error code, and where the user was
/// looking is not part of the finding.
final class TileLoading: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .mapTileLoading
    static let entity = Entity.WireID.mapView

    static let mapViewClassName = "MKMapView"
    static let setDelegate: Selector = .init("setDelegate:")
    static let didFinishLoading: Selector = .init("mapViewDidFinishLoadingMap:")
    static let didFailLoading: Selector = .init("mapViewDidFailLoadingMap:withError:")

    private let lock: NSLock = .init()
    private var completed: UInt64 = 0
    private var failures: UInt64 = 0
    private var followed: [Int] = []

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        guard let mapView = objc_getClass(mapViewClassName) as? AnyClass else {
            return
        }

        hooks.catchDelegateClass(at: setDelegate, on: mapView)
    }

    func observe(_ context: Context) {
        guard let mapView = objc_getClass(Self.mapViewClassName) as? AnyClass else {
            context.emit { out in
                out.put(.mapLoadsCompleted(0))
                out.put(.tileLoadFailures(0))
                out.put(.mechanismStatus("unavailable: this app does not use a map"))
            }
            return
        }

        let classes = context.registries.delegates(ObjectIdentifier(mapView))
        let token = classes.attachAndFollow { [weak self] delegateClass in
            self?.watch(delegateClass, context)
        }
        lock.withLock { followed.append(token) }
    }

    func stopObserving() {
        lock.withLock {
            completed = 0
            failures = 0
            followed.removeAll()
        }
    }

    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        let appWasListening =
            class_getInstanceMethod(delegateClass, Self.didFailLoading) != nil

        _ = context.swizzle.afterOrDefine(delegateClass, Self.didFinishLoading) {
            [weak self] _, _ in
            self?.finished(delegateClass, context)
        }
        _ = context.swizzle.afterOrDefine(
            delegateClass, Self.didFailLoading, takingTwoObjects: ()
        ) { [weak self] _, _, error in
            self?.failed(error, of: delegateClass, into: context)
        }

        context.emit { out in
            out.put(.mapLoadsCompleted(0))
            out.put(.tileLoadFailures(0))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.callbackImplemented(appWasListening))
        }
    }

    private func finished(_ delegateClass: AnyClass, _ context: Context) {
        let counts = lock.withLock { () -> (UInt64, UInt64) in
            completed += 1
            return (completed, failures)
        }
        context.emit { out in
            out.put(.mapLoadsCompleted(counts.0))
            out.put(.tileLoadFailures(counts.1))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
        }
    }

    /// The error is the finding. A failure with no error attached still counts,
    /// because the count is what separates a map that never drew from one the
    /// user simply had not panned.
    private func failed(
        _ error: AnyObject?,
        of delegateClass: AnyClass,
        into context: Context
    ) {
        let counts = lock.withLock { () -> (UInt64, UInt64) in
            failures += 1
            return (completed, failures)
        }
        context.emit { out in
            out.put(.mapLoadsCompleted(counts.0))
            out.put(.tileLoadFailures(counts.1))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            if let failure = error as? NSError {
                out.put(.errorDomain(failure.domain))
                out.put(.errorCode(Int32(truncatingIfNeeded: failure.code)))
            }
        }
    }
}
