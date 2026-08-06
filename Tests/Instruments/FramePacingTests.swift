@testable import Basset
import BassetECS
import Foundation
import Testing

/// The aggregation, tested against a `Tally` filled by hand. The link itself
/// needs a foreground window scene and a display producing frames, so the part
/// that can be tested on a host is the part that decides what a window of frames
/// means — which is also the part that can be wrong quietly.
struct FramePacingTests {
    @Test func aWindowWithNoFramesSaysNothing() {
        var out = readings()
        FramePacing.write(Tally(slots: 6), over: window(), into: &out)

        #expect(out.isEmpty)
    }

    /// An app drawing smoothly is the common case and must not be reported as a
    /// problem: frames counted, and no miss, no overrun.
    @Test func framesThatAllMadeTheDeadlineReportNoMisses() {
        let tally = Tally(slots: 6)
        tally.add(TallySlot(0), 120)

        var out = readings()
        FramePacing.write(tally, over: window(), into: &out)

        #expect(rendered(out.sealed(), .occurrenceCount) == "120")
        #expect(out.componentsWritten.contains(.deadlineMissCount) == false)
        #expect(out.componentsWritten.contains(.deadlineOverrunNanoseconds) == false)
    }

    @Test func missesArriveWithTheWorstOverrunThatCausedThem() {
        let tally = Tally(slots: 6)
        tally.add(TallySlot(0), 60)
        tally.add(TallySlot(1), 9)
        tally.raise(TallySlot(2), to: 4000000)

        var out = readings()
        FramePacing.write(tally, over: window(), into: &out)

        #expect(rendered(out.sealed(), .deadlineMissCount) == "9")
        #expect(rendered(out.sealed(), .deadlineOverrunNanoseconds) == "4000000")
    }

    /// The window rides the reading so a miss count can be read as a rate. Nine
    /// missed frames in a second and nine in a minute are different findings.
    @Test func theWindowIsCarriedSoACountCanBecomeARate() {
        let tally = Tally(slots: 6)
        tally.add(TallySlot(0), 1)

        var out = readings()
        FramePacing.write(tally, over: window(nanoseconds: 2000000000), into: &out)

        #expect(rendered(out.sealed(), .windowNanoseconds) == "2000000000")
    }

    @Test func commitTimeIsReportedAsBothTheTotalAndTheWorstOne() {
        let tally = Tally(slots: 6)
        tally.add(TallySlot(0), 10)
        tally.add(TallySlot(3), 25000000)
        tally.raise(TallySlot(4), to: 7000000)

        var out = readings()
        FramePacing.write(tally, over: window(), into: &out)

        #expect(rendered(out.sealed(), .totalNanoseconds) == "25000000")
        #expect(rendered(out.sealed(), .peakNanoseconds) == "7000000")
    }

    /// Draining is what makes the next window independent. A tally read without
    /// being emptied reports the same frames again a second later, and a capture
    /// built on it shows a problem that stopped happening.
    @Test func aWindowIsDrainedSoTheNextOneStandsAlone() {
        let tally = Tally(slots: 6)
        tally.add(TallySlot(0), 30)
        tally.add(TallySlot(1), 2)

        var first = readings()
        FramePacing.write(tally, over: window(), into: &first)

        var second = readings()
        FramePacing.write(tally, over: window(), into: &second)

        #expect(rendered(first.sealed(), .occurrenceCount) == "30")
        #expect(second.isEmpty)
    }

    private func window(nanoseconds: UInt64 = 1000000000) -> Context.FlushWindow {
        Context.FlushWindow(nanoseconds: nanoseconds)
    }

    private func readings() -> Readings {
        Readings(
            entity: .displayUpdate,
            instrumentName: "render.frame.pacing"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.WireID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
