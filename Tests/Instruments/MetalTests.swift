@testable import Basset
import BassetECS
import Foundation
import Testing

struct DrawablePresentationTests {
    private enum Slot {
        static let requested: TallySlot = .init(0)
        static let unavailable: TallySlot = .init(1)
        static let presented: TallySlot = .init(2)
        static let skipped: TallySlot = .init(3)
        static let intervalTotal: TallySlot = .init(4)
        static let intervalPeak: TallySlot = .init(5)
        static let lastPresented: TallySlot = .init(6)
    }

    @Test func awindowWithNoDrawableAskedForSaysNothing() {
        #expect(emit(from: Tally(slots: 7)).isEmpty)
    }

    @Test func presentedFramesAreCountedAgainstWhatWasAskedFor() {
        let tally = Tally(slots: 7)
        tally.add(Slot.requested, 60)
        tally.add(Slot.presented, 58)

        let reading = try? #require(emit(from: tally).first)

        #expect(count(.drawableRequestCount, in: reading) == 60)
        #expect(count(.occurrenceCount, in: reading) == 58)
    }

    /// Separate facts — one is a frame drawn and dropped, the other never reached to draw.
    @Test func skippedAndUnavailableAreReportedApart() {
        let tally = Tally(slots: 7)
        tally.add(Slot.requested, 10)
        tally.add(Slot.skipped, 3)
        tally.add(Slot.unavailable, 2)

        let reading = emit(from: tally).first

        #expect(count(.drawableSkippedCount, in: reading) == 3)
        #expect(count(.drawableUnavailableCount, in: reading) == 2)
    }

    /// A clean window should not carry two zeroes saying nothing went wrong.
    @Test func aWindowThatDroppedNothingCarriesNeitherCount() {
        let tally = Tally(slots: 7)
        tally.add(Slot.requested, 10)
        tally.add(Slot.presented, 10)

        let reading = emit(from: tally).first

        #expect(rendered(.drawableSkippedCount, in: reading) == nil)
        #expect(rendered(.drawableUnavailableCount, in: reading) == nil)
    }

    @Test func theIntervalTotalAndPeakRideTogether() {
        let tally = Tally(slots: 7)
        tally.add(Slot.requested, 3)
        tally.add(Slot.presented, 3)
        tally.add(Slot.intervalTotal, 33000000)
        tally.raise(Slot.intervalPeak, to: 25000000)

        let reading = emit(from: tally).first

        #expect(count(.totalNanoseconds, in: reading) == 33000000)
        #expect(count(.peakNanoseconds, in: reading) == 25000000)
    }

    /// One frame has nothing before it to measure an interval — a stale peak can't ride alone.
    @Test func aSingleFrameCarriesNoIntervalAndLeavesNoPeakBehind() {
        let tally = Tally(slots: 7)
        tally.add(Slot.requested, 1)
        tally.add(Slot.presented, 1)
        tally.raise(Slot.intervalPeak, to: 9999)

        let reading = emit(from: tally).first

        #expect(rendered(.totalNanoseconds, in: reading) == nil)
        #expect(rendered(.peakNanoseconds, in: reading) == nil)
        #expect(tally.read(Slot.intervalPeak) == 0, "the stale peak was drained")
    }

    /// The last frames of a burst land in a window asking nothing — reporting them is the point.
    @Test func framesPresentedAfterTheRequestWindowAreStillReported() {
        let tally = Tally(slots: 7)
        tally.add(Slot.presented, 4)
        tally.add(Slot.skipped, 2)

        let reading = emit(from: tally).first

        #expect(count(.occurrenceCount, in: reading) == 4)
        #expect(count(.drawableSkippedCount, in: reading) == 2)
        #expect(count(.drawableRequestCount, in: reading) == 0)
    }

    /// Counts left behind by a silent window would otherwise bleed into the next window's numbers.
    @Test func aWindowThatReportsNothingLeavesNothingForTheNext() {
        let tally = Tally(slots: 7)
        tally.add(Slot.unavailable, 5)

        #expect(emit(from: tally).isEmpty == false, "a refusal alone is worth a reading")
        #expect(emit(from: tally).isEmpty, "and nothing was carried into the next")
    }

    /// Measuring across an idle gap would report idle time as the worst frame interval.
    @Test func adrawnWindowKeepsTheCutoffAndAnIdleOneClearsIt() {
        let tally = Tally(slots: 7)
        tally.add(Slot.presented, 1)
        _ = tally.exchange(Slot.lastPresented, for: 900)

        _ = emit(from: tally)
        #expect(tally.read(Slot.lastPresented) == 900, "a window that drew keeps it")

        _ = emit(from: tally)
        #expect(tally.read(Slot.lastPresented) == 0, "an idle one lets it go")
    }

    /// A frame split across a flush boundary reports its interval even with no count in the window.
    @Test func anIntervalArrivingAloneIsReportedRatherThanDropped() {
        let tally = Tally(slots: 7)
        tally.add(Slot.intervalTotal, 8000000)
        tally.raise(Slot.intervalPeak, to: 8000000)

        let reading = emit(from: tally).first

        #expect(count(.totalNanoseconds, in: reading) == 8000000)
        #expect(count(.peakNanoseconds, in: reading) == 8000000)
    }

    /// Every counter is drained, or the next window reports these numbers again on top of its own.
    @Test func awindowDrainsEverythingItReported() {
        let tally = Tally(slots: 7)
        tally.add(Slot.requested, 10)
        tally.add(Slot.presented, 9)
        tally.add(Slot.skipped, 1)
        tally.add(Slot.unavailable, 4)
        tally.add(Slot.intervalTotal, 500)
        tally.raise(Slot.intervalPeak, to: 200)

        _ = emit(from: tally)

        #expect(emit(from: tally).isEmpty, "a second window found nothing left")
    }

    private func emit(from tally: Tally) -> [Entity] {
        var out = Readings(
            entity: DrawablePresentation.entity,
            instrumentName: DrawablePresentation.name
        )
        DrawablePresentation.write(
            tally,
            over: Context.FlushWindow(nanoseconds: 1000000000),
            into: &out
        )
        guard !out.isEmpty else {
            return []
        }

        return [out.sealed()] + out.sealedSiblings()
    }

    private func rendered(_ id: Component.ID, in entity: Entity?) -> String? {
        entity?.components.first { $0.id == id }?.value.rendered
    }

    private func count(_ id: Component.ID, in entity: Entity?) -> UInt64? {
        rendered(id, in: entity).flatMap(UInt64.init)
    }
}

/// The half a `write` test can't reach — declared slots, and the real class/selector it aims at.
struct DrawablePresentationWiringTests {
    @Test func itDeclaresEveryCounterItWrites() {
        #expect(DrawablePresentation.tallySlots == 7)
    }

    /// `write` reads slot 6 via `lastPresented` — declaring only six emitted breaks intervals.
    @Test func theHighestSlotItTouchesIsInsideWhatItDeclared() {
        let tally = Tally(slots: DrawablePresentation.tallySlots)

        #expect(tally.exchange(TallySlot(6), for: 5) == 0)
        #expect(tally.read(TallySlot(6)) == 5)
    }

    /// A swizzle on a nonexistent class/selector installs silently, same as an app that never drew.
    @Test func theLayerClassAndSelectorExist() throws {
        let layer = try #require(objc_getClass("CAMetalLayer") as? AnyClass)

        #expect(layer.instancesRespond(to: NSSelectorFromString("nextDrawable")))
    }

    @Test func itIsRegisteredAndStreamsFromTheMetalDomain() throws {
        let registration = try #require(
            Instruments.all.first { $0.id == .metalDrawablePresentation }
        )

        #expect(registration.name == "metal.drawable.presentation")
        #expect(registration.domain == .metal)
        #expect(registration.delivery == .stream)
        #expect(registration.tallySlots == 7)
    }

    /// A simulator presents through the Mac's GPU and display — hardware the app never runs on.
    @Test func itRefusesToRunOnASimulator() {
        #expect(InstrumentID.metalDrawablePresentation.availability.simulator == false)
    }
}

/// A stand-in for a presented drawable: the KVC key without CoreAnimation.
@objc private final class StampedDrawable: NSObject {
    @objc let presentedTime: Double

    init(_ time: Double) {
        presentedTime = time
    }
}

struct DrawableRecordTests {
    private enum Slot {
        static let presented: TallySlot = .init(2)
        static let skipped: TallySlot = .init(3)
    }

    @Test func aNonFiniteStampIsRefusedRatherThanReadAsASkip() {
        let tally = Tally(slots: 7)
        let hot = hotPath(over: tally)

        DrawablePresentation.record(StampedDrawable(.nan), hot)
        DrawablePresentation.record(StampedDrawable(.infinity), hot)
        DrawablePresentation.record(StampedDrawable(-.infinity), hot)

        #expect(tally.read(Slot.skipped) == 0)
        #expect(tally.read(Slot.presented) == 0)
    }

    @Test func azeroStampIsAFrameThatNeverReachedTheScreen() {
        let tally = Tally(slots: 7)

        DrawablePresentation.record(StampedDrawable(0), hotPath(over: tally))

        #expect(tally.read(Slot.skipped) == 1)
        #expect(tally.read(Slot.presented) == 0)
    }

    @Test func adrawableWithoutTheKeyIsIgnoredRatherThanRaisedAt() {
        let tally = Tally(slots: 7)

        DrawablePresentation.record(NSObject(), hotPath(over: tally))

        #expect(tally.read(Slot.skipped) == 0)
        #expect(tally.read(Slot.presented) == 0)
    }

    @Test func twoStampsAnIntervalApartCountAsPresented() {
        let tally = Tally(slots: 7)
        let hot = hotPath(over: tally)

        DrawablePresentation.record(StampedDrawable(1.0), hot)
        DrawablePresentation.record(StampedDrawable(1.016), hot)

        #expect(tally.read(Slot.presented) == 2)
        #expect(tally.read(Slot.skipped) == 0)
    }

    private func hotPath(over tally: Tally) -> HotPath {
        let status = AtomicStatus()
        status.activate()
        return HotPath(tally: tally, clock: Clock(), status: status)
    }
}
