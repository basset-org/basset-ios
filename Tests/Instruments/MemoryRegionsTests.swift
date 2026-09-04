@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct VMRegionWalkTests {
    private static let touchedBytes = 48 * 1024 * 1024

    private static let isSanitizerLoaded = ThreadWalker.isThreadSanitizerLoaded
        || dlsym(dlopen(nil, RTLD_LAZY), "__asan_init") != nil

    /// A touched allocation lands in a malloc tag as dirty pages, not somewhere untagged.
    @Test(.enabled(
        if: !isSanitizerLoaded,
        "TSan's and ASan's own allocators map outside the malloc tags"
    ))
    func aTouchedAllocationShowsUpDirtyUnderMalloc() {
        let block = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.touchedBytes)
        defer { block.deallocate() }
        block.initialize(repeating: 0x5a, count: Self.touchedBytes)

        let totals = VMRegionWalk.totalsByTag()
        let mallocDirty = totals
            .filter { VMTag.name($0.tag).hasPrefix("malloc") }
            .reduce(UInt64(0)) { $0 + $1.dirtyBytes }

        #expect(mallocDirty >= UInt64(Self.touchedBytes))
        #expect(totals.allSatisfy { $0.regionCount > 0 })
    }

    /// `KERN_SUCCESS` with a zero size would otherwise re-ask the same address forever.
    @Test func aZeroSizeRegionEndsTheWalkRatherThanLoopingOnIt() {
        var asked = 0
        let regions = VMRegionWalk.regions { address, size, info in
            asked += 1
            address = 0x1000
            size = 0
            info.user_tag = 3
            return KERN_SUCCESS
        }

        #expect(regions.isEmpty)
        #expect(asked == 1)
    }

    @Test func aProbeThatOverflowsTheAddressSpaceEndsTheWalk() {
        var asked = 0
        let regions = VMRegionWalk.regions { address, size, info in
            asked += 1
            address = vm_address_t.max - 4095
            size = 4096
            info.user_tag = 3
            info.pages_resident = 1
            return KERN_SUCCESS
        }

        #expect(regions.count == 1)
        #expect(asked == 1)
        #expect(regions[0].residentBytes == UInt64(vm_kernel_page_size))
    }

    @Test func rowsComeBiggestDirtyFirst() {
        let totals = VMRegionWalk.totalsByTag()

        #expect(totals.map(\.dirtyBytes) == totals.map(\.dirtyBytes).sorted(by: >))
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["CI"] == nil && !isSanitizerLoaded,
        "a wall-clock bound holds on an idle development machine only, under neither TSan nor ASan"
    ))
    func aWalkIsCheapEnoughForEveryWindow() {
        let started = DispatchTime.now().uptimeNanoseconds
        _ = VMRegionWalk.totalsByTag()
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        #expect(elapsed < 200000000)
    }
}

struct VMTagTests {
    @Test func theOwnersAReaderReachesForAreNamed() {
        #expect(VMTag.name(88) == "IOSurface")
        #expect(VMTag.name(100) == "IOAccelerator (Metal)")
        #expect(VMTag.name(68) == "Core Image")
        #expect(VMTag.name(70) == "ImageIO")
        #expect(VMTag.name(3) == "malloc large")
    }

    @Test func appSpecificAndUnknownTagsStillGetAName() {
        #expect(VMTag.name(240) == "app-specific 1")
        #expect(VMTag.name(255) == "app-specific 16")
        #expect(VMTag.name(200) == "tag 200")
    }
}

struct RegionLedgerTests {
    @Test func theFirstWalkIsAllGrowth() {
        var ledger = RegionLedger()

        let table = ledger.advance(to: [totals(88, dirty: 1000), totals(3, dirty: 500)])

        #expect(table.rows.map(\.dirtyDeltaBytes) == [1000, 500])
        #expect(table.dirtyBytes == 1500)
        #expect(table.regionCount == 2)
    }

    @Test func aChangeIsMeasuredAgainstThePreviousWalk() {
        var ledger = RegionLedger()
        _ = ledger.advance(to: [totals(88, dirty: 1000), totals(3, dirty: 500)])

        let table = ledger.advance(to: [totals(88, dirty: 1300), totals(3, dirty: 200)])

        #expect(table.rows.first { $0.totals.tag == 88 }?.dirtyDeltaBytes == 300)
        #expect(table.rows.first { $0.totals.tag == 3 }?.dirtyDeltaBytes == -300)
    }

    /// An owner gone from the map is a release, which is the reading that matters most.
    @Test func anOwnerThatVanishedIsReportedAsItsRelease() {
        var ledger = RegionLedger()
        _ = ledger.advance(to: [totals(88, dirty: 1000)])

        let table = ledger.advance(to: [])

        #expect(table.rows.count == 1)
        #expect(table.rows[0].totals.tag == 88)
        #expect(table.rows[0].dirtyDeltaBytes == -1000)
        #expect(table.dirtyBytes == 0)
    }

    @Test func theProcessRowLeadsAndEachOwnerFollowsNamed() {
        var ledger = RegionLedger()
        let table = ledger.advance(to: [totals(88, dirty: 1000), totals(3, dirty: 500)])
        var out = Readings(.process)

        table.write(into: &out, ceiling: 24)
        let process = out.build()
        let owners = out.additionalEntities()

        #expect(process.components.first { $0.known == .dirtyBytes }?.value.rendered == "1500")
        #expect(owners.count == 2)
        #expect(owners.allSatisfy { $0.known == .memoryRegion })
        #expect(owners[0]
            .components
            .first { $0.known == .memoryTag }?
            .value
            .rendered == "IOSurface")
        #expect(owners[0]
            .components
            .first { $0.known == .dirtyDeltaBytes }?
            .value
            .rendered == "1000")
    }

    @Test func aReleaseOutranksSmallerLiveOwnersForARow() {
        var ledger = RegionLedger()
        _ = ledger.advance(to: [totals(88, dirty: 5000)] + (1...3).map { totals(
            UInt32($0),
            dirty: 100
        ) })
        let table = ledger.advance(to: (1...3).map { totals(UInt32($0), dirty: 100) })
        var out = Readings(.process)

        table.write(into: &out, ceiling: 2)
        let owners = out.additionalEntities()

        #expect(owners[0]
            .components
            .first { $0.known == .memoryTag }?
            .value
            .rendered == "IOSurface")
        #expect(owners[0]
            .components
            .first { $0.known == .dirtyDeltaBytes }?
            .value
            .rendered == "-5000")
        #expect(owners.count == 3)
    }

    @Test func pastTheCeilingTheRestIsCountedNotListed() {
        var ledger = RegionLedger()
        let table = ledger.advance(to: (1...5).map { totals(UInt32($0), dirty: UInt64(100 * $0)) })
        var out = Readings(.process)

        table.write(into: &out, ceiling: 3)
        let owners = out.additionalEntities()

        #expect(owners.count == 4)
        #expect(owners[3].components.first { $0.known == .memoryTag }?.value.rendered == "other")
        #expect(
            owners[3].components.first { $0.known == .mechanismStatus }?.value.rendered
                == "truncated: 2 more owners"
        )
    }

    private func totals(_ tag: UInt32, dirty: UInt64, resident: UInt64? = nil) -> VMRegionTotals {
        VMRegionTotals(
            tag: tag,
            residentBytes: resident ?? dirty,
            dirtyBytes: dirty,
            compressedBytes: 0,
            regionCount: 1
        )
    }
}
