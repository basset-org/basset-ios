import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The main run loop stopped returning to idle. Watched from a thread of its
/// own, because the one surface that cannot be asked how blocked it is, is the
/// blocked one.
final class MainThreadHang: StreamingInstrument {
    static let id: InstrumentWireID = .mainThreadHang
    static let entity = Entity.WireID.mainThread

    /// Two seconds to report, checked five times within it. The threshold is
    /// Sentry's and Apple's alike; the divisor bounds how late the report is
    /// without making the thread wake more often than it has to.
    private static let threshold: UInt64 = 2000000000
    private static let pollsPerThreshold: UInt64 = 5

    private let heartbeat: MainRunLoopHeartbeat
    private let watch: HangWatch
    private let clock: Clock
    private let foreground: AtomicStatus = .init()
    private var watchdog: Thread?
    private var lifecycle: [NSObjectProtocol] = []

    convenience init() {
        self.init(
            heartbeat: MainRunLoopHeartbeat(),
            clock: Clock(),
            threshold: Self.threshold
        )
    }

    init(heartbeat: MainRunLoopHeartbeat, clock: Clock, threshold: UInt64) {
        self.heartbeat = heartbeat
        self.clock = clock
        self.watch = HangWatch(threshold: threshold)
    }

    func observe(_ context: Context) {
        foreground.activate()
        followApplicationState()
        heartbeat.start()

        let interval = Double(watch.threshold) / Double(Self.pollsPerThreshold) /
            1000000000
        let watching = Thread { [heartbeat, watch, clock, foreground] in
            var state = HangWatch.State()

            while !Thread.current.isCancelled {
                let deadline = Date().addingTimeInterval(interval)
                Thread.sleep(forTimeInterval: interval)
                guard context.isActive else {
                    continue
                }

                let verdict = watch.step(
                    &state,
                    HangWatch.Poll(
                        beat: heartbeat.read(),
                        now: clock.now(),
                        overshoot: Date().timeIntervalSince(deadline),
                        foreground: foreground.isActive,
                        debugged: Debugger.isAttached
                    )
                )

                switch verdict {
                case .quiet:
                    continue
                case .began(let nanoseconds, let turns):
                    context.emit { out in
                        out.put(.hangNanoseconds(nanoseconds))
                        out.put(.hangResolved(false))
                        out.put(.runLoopTurnCount(turns))
                    }
                    // While it is still stuck. Anything else the request enabled
                    // reads the frozen process here, not the recovered one.
                    context.fault(.hang)
                case .ended(let nanoseconds, let turns):
                    context.emit { out in
                        out.put(.hangNanoseconds(nanoseconds))
                        out.put(.hangResolved(true))
                        out.put(.runLoopTurnCount(turns))
                    }
                }
            }
        }
        watching.name = QueueLabel.mainThreadHang
        watching.start()
        watchdog = watching
    }

    func stopObserving() {
        watchdog?.cancel()
        watchdog = nil
        heartbeat.stop()
        lifecycle.forEach(NotificationCenter.default.removeObserver)
        lifecycle.removeAll()
    }

    /// Read from a flag rather than from `UIApplication`, whose state is only
    /// readable on the thread this instrument exists because it cannot reach.
    /// The flag goes stale in the safe direction: a backgrounded app whose
    /// notification never arrived is one whose main thread is busy anyway.
    private func followApplicationState() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycle = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [foreground] _ in foreground.activate() },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [foreground] _ in foreground.deactivate() },
        ]
        #endif
    }
}
