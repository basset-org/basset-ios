@testable import Basset
import BassetECS
import Foundation
import Testing

/// Aggregation tested against a hand-filled `Tally` — the part that can be wrong quietly.
struct FramePacingTests {
    @Test func aWindowWithNoFramesSaysNothing() {
        var out = readings()
        FramePacing.write(Tally(slots: 6), over: window(), into: &out)

        #expect(out.isEmpty)
    }

    /// Smooth drawing is the common case and must not be reported as a problem.
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

    /// The window rides along so a miss count can be read as a rate, not just a raw number.
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

    /// Draining makes the next window independent — an unemptied tally repeats the same frames.
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

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
