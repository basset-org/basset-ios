@testable import Basset
import BassetECS
import Foundation
import Testing

struct MemoryLedgerTests {
    @Test func theProcessReportsAFootprintItIsActuallyUsing() throws {
        let ledger = try #require(MemoryLedger.read())

        #expect(ledger.usedBytes > 0)
    }

    /// Two calls a moment apart on a process that is not deliberately allocating
    /// still differ by a few pages. What must not move is the order of magnitude:
    /// a footprint that halves between reads is a struct being read at the wrong
    /// offset, not an app freeing memory.
    @Test func twoReadsAgreeOnTheOrderOfMagnitude() throws {
        let first = try #require(MemoryLedger.read())
        let second = try #require(MemoryLedger.read())

        let ratio = Double(max(first.usedBytes, second.usedBytes))
            / Double(min(first.usedBytes, second.usedBytes))
        #expect(ratio < 2)
    }

    @Test func theLimitIsWhatIsUsedPlusWhatIsLeft() {
        let ledger = MemoryLedger(usedBytes: 400, availableBytes: 600)

        #expect(ledger.limitBytes == 1000)
    }

    /// A footprint with no denominator is the whole reason this type exists, and
    /// half a denominator is worse than none — it invites a reader to subtract a
    /// limit that was never measured.
    @Test func aLedgerWithNoHeadroomOffersNoLimitEither() {
        let ledger = MemoryLedger(usedBytes: 400, availableBytes: nil)

        #expect(ledger.limitBytes == nil)
    }

    @Test func headroomAndLimitAreWrittenTogetherOrNotAtAll() {
        var complete = readings()
        MemoryLedger(usedBytes: 400, availableBytes: 600).write(into: &complete)

        var footprintOnly = readings()
        MemoryLedger(usedBytes: 400, availableBytes: nil).write(into: &footprintOnly)

        #expect(complete.componentsWritten == [
            .memoryUsedBytes,
            .memoryAvailableBytes,
            .memoryLimitBytes,
        ])
        #expect(footprintOnly.componentsWritten == [.memoryUsedBytes])
    }

    private func readings() -> Readings {
        Readings(
            entity: .process,
            instrumentName: "memory.footprint"
        )
    }
}
