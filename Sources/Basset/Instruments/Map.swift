import BassetECS
import Foundation
import ObjectiveC

/// Defines MKMapView's tile-loading callbacks when the app has none; never reads coordinates.
final class TileLoading: Streamable, PlainInstrument, LoadTimeInstall {
    private struct State {
        var completed: UInt64 = 0
        var failures: UInt64 = 0
        var followed: [Int] = []
    }

    static let id: InstrumentID = .mapTileLoading
    static let entity = Entity.ID.mapView

    static let mapViewClassName = "MKMapView"
    static let setDelegate: Selector = .init("setDelegate:")
    static let didFinishLoading: Selector = .init("mapViewDidFinishLoadingMap:")
    static let didFailLoading: Selector = .init("mapViewDidFailLoadingMap:withError:")

    private let guarded: Mutex<State> = .init(State())

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        guard let mapView = objc_getClass(mapViewClassName) as? AnyClass else {
            return
        }

        hooks.trackDelegateClass(at: setDelegate, on: mapView)
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
        guarded.withLock { $0.followed.append(token) }
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
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
        let counts = guarded.withLock { state -> (UInt64, UInt64) in
            state.completed += 1
            return (state.completed, state.failures)
        }
        context.emit { out in
            out.put(.mapLoadsCompleted(counts.0))
            out.put(.tileLoadFailures(counts.1))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
        }
    }

    /// Counted even without an error attached, since the count is the finding.
    private func failed(
        _ error: AnyObject?,
        of delegateClass: AnyClass,
        into context: Context
    ) {
        let counts = guarded.withLock { state -> (UInt64, UInt64) in
            state.failures += 1
            return (state.completed, state.failures)
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
