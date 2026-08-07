import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Whether the app finished each frame inside the budget the system gave it.
///
/// **`UIUpdateLink` rather than `CADisplayLink`**, for two reasons that are not
/// the timestamps — `CADisplayLink` carries `targetTimestamp` and `duration` and
/// tracks a variable refresh rate perfectly well.
///
/// First, `requiresContinuousUpdates`, left false here. `CADisplayLink` has
/// `isPaused` and no equivalent: once unpaused on a run loop it fires on every
/// vsync unconditionally, so an idle app that would have drawn nothing takes 120
/// main-run-loop wakeups a second and never reaches idle — a measurement creating
/// the cost it exists to report. `UIUpdateLink` rides the updates the app was
/// already producing, and an idle app pays nothing.
///
/// Second, `CADisplayLink` cannot see inside a frame. Its callback runs at
/// run-loop dispatch, before UIKit lays out, draws and commits, so the only thing
/// measurable is callback-to-callback interval — the app's work and its idle time
/// added together. `.beforeCATransactionCommit` and `.afterCATransactionCommit`
/// bracket the commit, which is where layout and drawing are actually paid for.
///
/// No fallback is built. `render.frame.pacing` does not activate below iOS 18,
/// which is an honest absence rather than a reading bought at the app's expense.
///
/// **The limit:** presentation happens in `backboardd`, out of process.
/// Everything here measures this side of that boundary — what the app produced
/// and when it finished — never what the screen showed. A frame finished on time
/// can still be presented late.
final class FramePacing: StreamingInstrument {
    private enum Slot {
        static let frames: TallySlot = .init(0)
        static let misses: TallySlot = .init(1)
        static let worstOverrun: TallySlot = .init(2)
        static let commitTotal: TallySlot = .init(3)
        static let commitPeak: TallySlot = .init(4)
        static let worstLatency: TallySlot = .init(5)
    }

    static let id: InstrumentID = .framePacing
    static let entity = Entity.ID.displayUpdate

    // `UIUpdateLink` is iOS 18. Below that the only mechanism available changes
    // the app's behaviour, so the instrument reports nothing rather than
    // reporting something at the app's expense.

    #if canImport(UIKit)
    private var link: AnyObject?
    #endif
    private let commitStarted: Mutable<UInt64> = .init(0)

    init() {}

    static func write(
        _ tally: Tally,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        let frames = tally.take(Slot.frames)
        // No frames is the app drawing nothing, which is ordinary while it sits
        // idle and is not worth a reading a second saying so.
        guard frames > 0 else {
            return
        }

        out.put(.occurrenceCount(frames))
        out.put(.windowNanoseconds(window.nanoseconds))

        let misses = tally.take(Slot.misses)
        let overrun = tally.take(Slot.worstOverrun)
        let commitTotal = tally.take(Slot.commitTotal)
        let commitPeak = tally.take(Slot.commitPeak)
        let latency = tally.take(Slot.worstLatency)

        if misses > 0 {
            out.put(.deadlineMissCount(UInt32(clamping: misses)))
            out.put(.deadlineOverrunNanoseconds(overrun))
        }
        if commitTotal > 0 {
            out.put(.totalNanoseconds(commitTotal))
            out.put(.peakNanoseconds(commitPeak))
        }
        if latency > 0 {
            out.put(.presentationLatencyNanoseconds(latency))
        }
    }

    func observe(_ context: Context) {
        #if canImport(UIKit)
        guard #available(iOS 18.0, *) else {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: UIUpdateLink needs iOS 18"))
            }
            return
        }
        guard let scene = Self.activeScene() else {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: no foreground window scene"))
            }
            return
        }

        let update = UIUpdateLink(windowScene: scene)
        // The whole basis of the mechanism being invisible. Left true, the link
        // demands a frame every vsync whether the app wanted one or not.
        update.requiresContinuousUpdates = false
        install(update, context.hotPath)
        update.isEnabled = true
        link = update

        context.flush(every: .seconds(1)) { [tally = context.tally] out, window in
            Self.write(tally, over: window, into: &out)
        }
        #endif
    }

    func stopObserving() {
        #if canImport(UIKit)
        if #available(iOS 18.0, *), let update = link as? UIUpdateLink {
            update.isEnabled = false
        }
        link = nil
        #endif
    }

    #if canImport(UIKit)
    /// Both callbacks run on the main thread once per frame, at up to 120 Hz.
    /// They do arithmetic and atomic increments and nothing else: no allocation,
    /// no lock, no emit. A frame instrument that costs a frame is the one thing
    /// this domain cannot ship.
    @available(iOS 18.0, *)
    private func install(_ update: UIUpdateLink, _ hot: HotPath) {
        let started = commitStarted
        update.addAction(to: .beforeCATransactionCommit) { _, _ in
            _ = started.take(hot.now().nanoseconds)
        }
        update.addAction(to: .afterCATransactionCommit) { _, info in
            let finished = hot.now().nanoseconds
            let began = started.take(0)
            hot.add(Slot.frames)

            if began > 0, finished > began {
                let spent = finished - began
                hot.add(Slot.commitTotal, spent)
                hot.raise(Slot.commitPeak, to: spent)
            }

            // When the work had to be finished by, which is earlier than when
            // the frame would be shown — the actionable instant of the two.
            let overrun = CACurrentMediaTime() - info.completionDeadlineTime
            if overrun > 0 {
                hot.add(Slot.misses)
                hot.raise(Slot.worstOverrun, to: UInt64(overrun * 1000000000))
            }

            let latency = info.estimatedPresentationTime - info.modelTime
            if latency > 0 {
                hot.raise(Slot.worstLatency, to: UInt64(latency * 1000000000))
            }
        }
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    #endif
}
