import BassetECS
import Foundation

/// Interval between presented drawables; never compared to another clock of unknown base.
final class DrawablePresentation: Streamable, PlainInstrument {
    private enum Slot {
        static let requested: TallySlot = .init(0)
        static let unavailable: TallySlot = .init(1)
        static let presented: TallySlot = .init(2)
        static let skipped: TallySlot = .init(3)
        static let intervalTotal: TallySlot = .init(4)
        static let intervalPeak: TallySlot = .init(5)
        static let lastPresented: TallySlot = .init(6)
    }

    static let id: InstrumentID = .metalDrawablePresentation
    static let entity = Entity.ID.metalDrawable
    static let tallySlots = 7

    private static let layerClassName = "CAMetalLayer"
    private static let nextDrawableSelector = "nextDrawable"
    private static let presentedTimeKey = "presentedTime"

    init() {}

    static func write(
        _ tally: Tally,
        over elapsed: Context.FlushWindow,
        into out: inout Readings
    ) {
        // All slots drained together: a drawable presents after the request call returns.
        let requested = tally.take(Slot.requested)
        let presented = tally.take(Slot.presented)
        let skipped = tally.take(Slot.skipped)
        let unavailable = tally.take(Slot.unavailable)
        let total = tally.take(Slot.intervalTotal)
        let peak = tally.take(Slot.intervalPeak)

        // total counts as activity: a split flush lands count and interval in different windows.
        guard requested > 0 || presented > 0 || skipped > 0 || unavailable > 0
            || total > 0
        else {
            // Nothing drew; the next frame starts a fresh interval, not a span across the idle gap.
            _ = tally.take(Slot.lastPresented)
            return
        }

        out.put(.windowNanoseconds(elapsed.nanoseconds))
        out.put(.drawableRequestCount(requested))
        out.put(.occurrenceCount(presented))
        if skipped > 0 {
            out.put(.drawableSkippedCount(skipped))
        }
        if unavailable > 0 {
            out.put(.drawableUnavailableCount(unavailable))
        }

        // Only from the second presented frame: the first has nothing to measure against.
        if total > 0 {
            out.put(.totalNanoseconds(total))
            out.put(.peakNanoseconds(peak))
        }
    }

    /// Runs on a thread the system owns, once per presented frame.
    static func record(_ drawable: AnyObject, _ hot: HotPath) {
        // A custom layer can vend a drawable without the key; unanswered KVC raises.
        guard hot.isActive,
              drawable.responds(to: NSSelectorFromString(presentedTimeKey)),
              let seconds = (drawable.value(forKey: presentedTimeKey) as? NSNumber)?
              .doubleValue
        else {
            return
        }

        // Non-finite or absurd is malformed metadata, refused before it can read as a skip.
        guard seconds.isFinite, seconds < 1000000000 else {
            return
        }

        // Zero reads as a frame that never reached the screen, not one shown at a clock's origin.
        guard seconds > 0 else {
            hot.add(Slot.skipped)
            return
        }

        hot.add(Slot.presented)

        let shownAt = UInt64(seconds * 1000000000)
        let before = hot.exchange(Slot.lastPresented, for: shownAt)
        guard before > 0, shownAt > before else {
            return
        }

        let interval = shownAt - before
        hot.add(Slot.intervalTotal, interval)
        hot.raise(Slot.intervalPeak, to: interval)
    }

    func observe(_ context: Context) {
        guard let layer = objc_getClass(Self.layerClassName) as? AnyClass else {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: this app does not use Metal"))
            }
            return
        }

        let hot = context.hotPath
        // One handler made once and handed to every drawable, not built per frame.
        let presented: @convention(block) (AnyObject) -> Void = { drawable in
            Self.record(drawable, hot)
        }

        _ = context.swizzle.afterFactory(
            layer,
            NSSelectorFromString(Self.nextDrawableSelector)
        ) { _, made in
            guard hot.isActive else {
                return
            }

            hot.add(Slot.requested)
            guard let drawable = made else {
                // Given none: every drawable the layer has is still in flight.
                hot.add(Slot.unavailable)
                return
            }

            let handlerSelector = NSSelectorFromString("addPresentedHandler:")
            // A custom layer can vend a drawable without the method; a bare perform raises.
            guard drawable.responds(to: handlerSelector) else {
                return
            }

            _ = drawable.perform(handlerSelector, with: presented)
        }

        context.flush(every: .seconds(1)) { [tally = context.tally] out, elapsed in
            Self.write(tally, over: elapsed, into: &out)
        }
    }

    func stopObserving() {}
}
