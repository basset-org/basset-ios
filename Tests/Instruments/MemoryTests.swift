@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct MemoryLedgerTests {
    @Test func theProcessReportsAFootprintItIsActuallyUsing() throws {
        let ledger = try #require(MemoryLedger.read())

        #expect(ledger.usedBytes > 0)
    }

    /// A footprint that halves between reads means the struct is read at the wrong offset.
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

    /// Half a denominator is worse than none — invites subtracting a limit never measured.
    @Test func aLedgerWithNoHeadroomOffersNoLimitEither() {
        let ledger = MemoryLedger(usedBytes: 400, availableBytes: nil)

        #expect(ledger.limitBytes == nil)
    }

    @Test func headroomAndLimitAreWrittenTogetherOrNotAtAll() {
        var complete = readings()
        MemoryLedger(usedBytes: 400, availableBytes: 600).write(into: &complete)

        var footprintOnly = readings()
        MemoryLedger(usedBytes: 400, availableBytes: nil).write(into: &footprintOnly)

        #expect(complete.build().componentIDs == [
            .memoryUsedBytes,
            .memoryAvailableBytes,
            .memoryLimitBytes,
        ])
        #expect(footprintOnly.build().componentIDs == [.memoryUsedBytes])
    }

    private func readings() -> Readings {
        Readings(.process)
    }
}
