@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

/// Aggregation tested against a hand-filled `Tally` — the part that can be wrong quietly.
struct FrameRateTests {
    @Test func aWindowWithNoTicksSaysNothing() {
        var out = readings()
        FrameRate.write(Tally(slots: 1), over: window(), into: &out)

        #expect(out.isEmpty)
    }

    @Test func fpsIsTicksDividedByTheWindowInSeconds() {
        let tally = Tally(slots: 1)
        tally.add(TallySlot(0), 60)

        var out = readings()
        FrameRate.write(tally, over: window(nanoseconds: 2000000000), into: &out)

        #expect(rendered(out.build(), .fps) == "30.0")
    }

    /// The window rides along so a tick count can be read as a rate, not just a raw number.
    @Test func theWindowIsCarriedSoACountCanBecomeARate() {
        let tally = Tally(slots: 1)
        tally.add(TallySlot(0), 1)

        var out = readings()
        FrameRate.write(tally, over: window(nanoseconds: 2000000000), into: &out)

        #expect(rendered(out.build(), .windowNanoseconds) == "2000000000")
    }

    /// Draining makes the next window independent — an unemptied tally repeats the same ticks.
    @Test func aWindowIsDrainedSoTheNextOneStandsAlone() {
        let tally = Tally(slots: 1)
        tally.add(TallySlot(0), 60)

        var first = readings()
        FrameRate.write(tally, over: window(), into: &first)

        var second = readings()
        FrameRate.write(tally, over: window(), into: &second)

        #expect(rendered(first.build(), .fps) == "60.0")
        #expect(second.isEmpty)
    }

    private func window(nanoseconds: UInt64 = 1000000000) -> Context.FlushWindow {
        Context.FlushWindow(nanoseconds: nanoseconds)
    }

    private func readings() -> Readings {
        Readings(.displayUpdate)
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.known == id }?.value.rendered
    }
}
