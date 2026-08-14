@testable import Basset
import BassetECS
import Foundation
import Testing

/// A mistake in these counters costs a number, never the host app.
struct TallySlotTests {
    /// Registration only — that the runner hands the count over is `TallyHandoffTests`'s claim.
    @Test func framePacingDeclaresTheSixCountersItWrites() throws {
        let pacing = try #require(Instruments.all.first { $0.id == .framePacing })

        #expect(pacing.tallySlots == 6)
    }

    @Test func anInstrumentThatDeclaresNothingGetsTheSharedDefault() {
        #expect(ViewLayoutPass.tallySlots == 4)
    }

    /// Runs on a frame commit inside somebody else's app, where ending the process is never right.
    @Test func aSlotPastTheEndIsRefusedRatherThanTrapped() {
        let tally = Tally(slots: 2)

        tally.add(TallySlot(7), 99)
        tally.raise(TallySlot(7), to: 99)

        #expect(tally.read(TallySlot(7)) == 0)
        #expect(tally.take(TallySlot(7)) == 0)
        #expect(tally.exchange(TallySlot(7), for: 99) == 0)
    }

    @Test func refusingOneSlotLeavesTheOthersCounting() {
        let tally = Tally(slots: 2)

        tally.add(TallySlot(9), 5)
        tally.add(.first, 3)

        #expect(tally.take(.first) == 3)
    }

    /// A single-step swap, so two arrivals at once cannot both read the same predecessor.
    @Test func exchangeReturnsWhatItReplaced() {
        let tally = Tally(slots: 1)

        #expect(tally.exchange(.first, for: 100) == 0)
        #expect(tally.exchange(.first, for: 250) == 100)
        #expect(tally.read(.first) == 250)
    }

    @Test func exchangeUnderConcurrentWritersLosesNothing() async {
        let tally = Tally(slots: 1)
        let writers = 8
        let each = 500

        let replaced = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< writers {
                group.addTask {
                    var seen = 0
                    for _ in 0 ..< each where tally.exchange(.first, for: 1) == 1 {
                        seen += 1
                    }
                    return seen
                }
            }
            var total = 0
            for await count in group {
                total += count
            }
            return total
        }

        // A lost update would show up as a count below this.
        #expect(replaced == writers * each - 1)
        #expect(tally.read(.first) == 1)
    }
}

/// The inits are public API an integrator's own instrument can reach with any value.
struct TallyMisuseTests {
    @Test func aZeroSlotTallyRefusesEveryWriteRatherThanTrapping() {
        let tally = Tally(slots: 0)

        tally.add(.first)
        tally.raise(.first, to: 9)

        #expect(tally.capacity == 0)
        #expect(tally.read(.first) == 0)
        #expect(tally.exchange(.first, for: 9) == 0)
    }

    @Test func aNegativeCapacityReadsAsZeroSlots() {
        let tally = Tally(slots: -3)

        tally.add(.first)

        #expect(tally.capacity == 0)
        #expect(tally.read(.first) == 0)
    }

    @Test func aNegativeSlotIsRefusedRatherThanTrapped() {
        let tally = Tally(slots: 2)

        tally.add(TallySlot(-1), 5)

        #expect(tally.read(TallySlot(-1)) == 0)
        #expect(tally.take(TallySlot(-1)) == 0)
    }
}
