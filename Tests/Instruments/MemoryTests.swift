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

    @Test func theSystemsFreeMemoryIsReadFromTheHost() throws {
        let ledger = try #require(MemoryLedger.read())

        #expect((ledger.systemFreeBytes ?? 0) > 0)
        #expect((ledger.systemFreeBytes ?? 0) < ledger.systemPhysicalBytes)
    }

    /// `mach_host_self()` hands out a send right per call; a read a second would leak them.
    @Test func repeatedReadsHoldOneHostRight() throws {
        _ = MemoryLedger.read()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let send = mach_port_right_t(MACH_PORT_RIGHT_SEND)
        var before: mach_port_urefs_t = 0
        try #require(mach_port_get_refs(mach_task_self_, host, send, &before) == KERN_SUCCESS)

        for _ in 0 ..< 8 {
            _ = MemoryLedger.read()
        }

        var after: mach_port_urefs_t = 0
        try #require(mach_port_get_refs(mach_task_self_, host, send, &after) == KERN_SUCCESS)
        #expect(after == before)
    }

    @Test func systemFreeIsWrittenAsBytesAndAsAShareOfPhysical() {
        var out = readings()
        MemoryLedger(
            usedBytes: 400,
            availableBytes: 600,
            systemFreeBytes: 250,
            systemPhysicalBytes: 1000
        ).write(into: &out)
        let built = out.build()

        #expect(built.componentIDs.contains(.systemFreeBytes))
        #expect(built.componentIDs.contains(.systemFreeRatio))
        #expect(built.components.first { $0.known == .systemFreeRatio }?.value.rendered == "0.25")
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
            .memoryUsageRatio,
        ])
        #expect(
            complete.build().components.first { $0.known == .memoryUsageRatio }?.value.rendered
                == "0.4"
        )
        #expect(footprintOnly.build().componentIDs == [.memoryUsedBytes])
    }

    private func readings() -> Readings {
        Readings(.process)
    }
}
