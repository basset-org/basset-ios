import BassetEntityComponent
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// UIUpdateLink over CADisplayLink: unpaused CADisplayLink fires every vsync even when idle.
final class FramePacing: Streamable, PlainInstrument {
    private enum Slot {
        static let frames: TallySlot = .init(0)
        static let misses: TallySlot = .init(1)
        static let worstOverrun: TallySlot = .init(2)
        static let commitTotal: TallySlot = .init(3)
        static let commitPeak: TallySlot = .init(4)
        static let worstLatency: TallySlot = .init(5)
    }

    static let id: InstrumentID = .framePacing
    /// Six slots; the shared default is four.
    static let tallySlots = 6

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
        // No frames means idle, not worth reporting every second.
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

        // connectedScenes and UIUpdateLink are main-thread-only; activation arrives on any thread.
        DispatchQueue.main.async { [weak self] in
            guard let self, context.isActive else {
                return
            }
            guard let scene = Self.activeScene() else {
                context.emit { out in
                    out.put(
                        .mechanismStatus("unavailable: no foreground window scene")
                    )
                }
                return
            }

            let update = UIUpdateLink(windowScene: scene)
            // Phase actions first: requiresContinuousUpdates traps on a link that has none.
            self.install(update, context.hotPath)
            // Left true, the link would demand a frame every vsync regardless.
            update.requiresContinuousUpdates = false
            update.isEnabled = true
            self.link = update

            // Registered only once a link exists, else it wakes the app every second for nothing.
            context.flush(every: .seconds(1)) { [tally = context.tally] out, window in
                Self.write(tally, over: window, into: &out)
            }
        }
        #endif
    }

    func stopObserving() {
        #if canImport(UIKit)
        // isEnabled is main-thread-only; link is only touched here, so no lock needed.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            if #available(iOS 18.0, *), let update = self.link as? UIUpdateLink {
                update.isEnabled = false
            }
            self.link = nil
        }
        #endif
    }

    #if canImport(UIKit)
    /// Runs on the main thread up to 120 Hz: arithmetic and atomic increments only, no allocation.
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

            // completionDeadlineTime is when work had to finish, earlier than when it's shown.
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
        HostApplication.shared?
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
    #endif
}
