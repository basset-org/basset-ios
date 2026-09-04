@testable import Basset
import BassetEntityComponent
import Foundation
import Testing
#if canImport(CoreImage)
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#endif

struct SurfaceLedgerTests {
    @Test func theFirstWalkIsAllAppeared() {
        var ledger = SurfaceLedger()

        let window = ledger.advance(to: [region(0x1000, 4096), region(0x9000, 8192)])

        #expect(window.appeared.count == 2)
        #expect(window.vanished.isEmpty)
        #expect(window.liveBytes == 12288)
    }

    @Test func aSurfaceGoneFromTheMapIsVanishedAndANewOneAppeared() {
        var ledger = SurfaceLedger()
        _ = ledger.advance(to: [region(0x1000, 4096), region(0x9000, 8192)])

        let window = ledger.advance(to: [region(0x9000, 8192), region(0xf000, 65536)])

        #expect(window.appeared == [region(0xf000, 65536)])
        #expect(window.vanished == [region(0x1000, 4096)])
        #expect(window.appearedBytes == 65536)
        #expect(window.vanishedBytes == 4096)
    }

    /// Same address, different size is a different surface: the old one went, a new one came.
    @Test func aResizedRegionIsBothAVanishAndAnAppear() {
        var ledger = SurfaceLedger()
        _ = ledger.advance(to: [region(0x1000, 4096)])

        let window = ledger.advance(to: [region(0x1000, 8192)])

        #expect(window.appeared.count == 1)
        #expect(window.vanished.count == 1)
    }

    @Test func theWindowRowLeadsAndEachAppearedSurfaceFollowsLargestFirst() {
        var ledger = SurfaceLedger()
        let window = ledger.advance(to: [region(0x1000, 4096), region(0x9000, 65536)])
        var out = Readings(.surfaceWindow)

        window.write(into: &out, ceiling: 12)
        let row = out.build()
        let surfaces = out.additionalEntities()

        #expect(row.components.first { $0.known == .appearedCount }?.value.rendered == "2")
        #expect(surfaces.count == 2)
        #expect(surfaces.allSatisfy { $0.known == .surface })
        #expect(surfaces[0]
            .components
            .first { $0.known == .residentBytes }?
            .value
            .rendered == "65536")
    }

    @Test func pastTheCeilingTheRestIsCounted() {
        var ledger = SurfaceLedger()
        let window = ledger.advance(to: (1...5).map { region(UInt64($0) * 0x1000, 4096) })
        var out = Readings(.surfaceWindow)

        window.write(into: &out, ceiling: 2)
        let surfaces = out.additionalEntities()

        #expect(surfaces.count == 3)
        #expect(
            surfaces[2].components.first { $0.known == .mechanismStatus }?.value.rendered
                == "truncated: 3 more surfaces"
        )
    }

    /// Resident pages are what a window sums; mapped size is part of the surface's identity.
    @Test func residentBytesAreSummedAndIdentityIgnoresThem() {
        var ledger = SurfaceLedger()
        _ = ledger.advance(to: [
            VMRegion(address: 0x1000, mappedBytes: 8192, residentBytes: 4096, tag: 88),
        ])

        let window = ledger.advance(to: [
            VMRegion(address: 0x1000, mappedBytes: 8192, residentBytes: 8192, tag: 88),
        ])

        #expect(window.appeared.isEmpty)
        #expect(window.vanished.isEmpty)
        #expect(window.liveBytes == 8192)
    }

    private func region(_ address: UInt64, _ bytes: UInt64) -> VMRegion {
        VMRegion(
            address: address,
            mappedBytes: bytes,
            residentBytes: bytes,
            tag: VMRegionWalk.ioSurfaceTag
        )
    }
}

struct LargeImageLedgerTests {
    private let photo = LargeImageLedger.Key(source: "data", width: 4032, height: 3024)

    @Test func onlyTheFirstSightingOfASizeAsksForAStack() {
        var ledger = LargeImageLedger()

        let first = ledger.count(photo)
        let second = ledger.count(photo)

        #expect(first)
        #expect(!second)
    }

    @Test func drainingWritesCountAndCallersThenForgets() {
        var ledger = LargeImageLedger()
        _ = ledger.count(photo)
        _ = ledger.count(photo)
        ledger.attach([0x1000, 0x2000], to: photo)

        let built = ledger.drain().built
        let again = ledger.drain()
        var out = Readings(.imageSource)
        built[0].write(into: &out)
        let row = out.build()

        #expect(built.count == 1)
        #expect(built[0].count == 2)
        #expect(again.built.isEmpty)
        #expect(again.unlistedSizes == 0)
        #expect(row.components.first { $0.known == .imageSource }?.value.rendered == "data")
        #expect(row.components.first { $0.known == .occurrenceCount }?.value.rendered == "2")
        #expect(row.components.filter { $0.known == .frameAddress }.count == 2)
    }

    @Test func sourcesAreListedInTheOrderTheyFirstAppeared() {
        var ledger = LargeImageLedger()
        let buffer = LargeImageLedger.Key(source: "pixelBuffer", width: 4032, height: 3024)
        _ = ledger.count(buffer)
        _ = ledger.count(photo)
        _ = ledger.count(buffer)

        #expect(ledger.drain().built.map(\.key.source) == ["pixelBuffer", "data"])
    }

    @Test func pastTheCeilingANewSizeIsCountedNotWalked() {
        var ledger = LargeImageLedger(ceiling: 2)
        let sizes = (1...4)
            .map { LargeImageLedger.Key(source: "data", width: Int32($0), height: 1) }

        let walked = sizes.map { ledger.count($0) }
        _ = ledger.count(sizes[3])
        let drained = ledger.drain()

        #expect(walked == [true, true, false, false])
        #expect(drained.built.map(\.key.width) == [1, 2])
        #expect(drained.unlistedSizes == 2)
        #expect(ledger.drain().unlistedSizes == 0)
    }

    @Test func pixelsMultiplyWidthByHeight() {
        #expect(photo.pixels == 12192768)
    }

    /// `CGRect.infinite` passes `isFinite` and overflows `Int32`; converting it would trap.
    @Test func anExtentPastInt32OrEmptyIsNoKey() {
        let finite = CGRect(x: 0, y: 0, width: 4032, height: 3024)

        #expect(LargeImageLedger.Key(source: "data", extent: finite) == photo)
        #expect(LargeImageLedger.Key(source: "data", extent: .infinite) == nil)
        #expect(LargeImageLedger.Key(source: "data", extent: .null) == nil)
        #expect(LargeImageLedger.Key(source: "data", extent: .zero) == nil)
        #expect(LargeImageLedger.Key(
            source: "data", extent: CGRect(x: 0, y: 0, width: Double(Int32.max) + 1, height: 1)
        ) == nil)
    }
}

#if canImport(CoreImage)
struct ImagingSurfacesWiringTests {
    private static let side = 1200

    private static func makeCGImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context?.makeImage()
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    @Test func aLargeImageBuiltFromDataAndFromACGImageIsSeenBySource() throws {
        let harness = InstrumentHarness<ImagingSurfaces> {
            ImagingSurfaces(config: .init(thresholdMegapixels: 1))
        }
        harness.start()
        defer { harness.stop() }

        let cgImage = try #require(Self.makeCGImage())
        let png = try #require(Self.pngData(cgImage))
        let fromCGImage = CIImage(cgImage: cgImage)
        let fromData = CIImage(data: png)

        let seen = harness.instrument.pendingImageKeys
        #expect(fromCGImage.extent.width == CGFloat(Self.side))
        #expect(fromData?.extent.width == CGFloat(Self.side))
        #expect(seen.map(\.source).contains("cgImage"))
        #expect(seen.map(\.source).contains("data"))
        #expect(seen.allSatisfy { $0.width == Int32(Self.side) && $0.height == Int32(Self.side) })
    }

    /// A color image is infinite in every direction, the extent the ledger must refuse.
    @Test func aColorImageHasAnInfiniteExtentAndNoKey() {
        let color = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))

        #expect(color.extent == .infinite)
        #expect(LargeImageLedger.Key(source: "color", extent: color.extent) == nil)
    }

    @Test func anImageUnderTheThresholdIsNotRecorded() throws {
        let harness = InstrumentHarness<ImagingSurfaces> {
            ImagingSurfaces(config: .init(thresholdMegapixels: 2))
        }
        harness.start()
        defer { harness.stop() }

        let cgImage = try #require(Self.makeCGImage())
        _ = CIImage(cgImage: cgImage)

        #expect(harness.instrument.pendingImageKeys.isEmpty)
    }
}
#endif

struct VMRegionEnumerationTests {
    /// One walk, folded two ways — a second walk would see a map that has moved on.
    @Test func regionsUnderATagAreTheTagsWholeTotal() {
        let walked = VMRegionWalk.regions()
        let totals = VMRegionWalk.totalsByTag(walked)
        guard let malloc = totals.first(where: { $0.tag == 3 }) else {
            return
        }

        let listed = walked.filter { $0.tag == 3 }

        #expect(UInt32(listed.count) == malloc.regionCount)
        #expect(listed.allSatisfy { $0.tag == 3 && $0.mappedBytes > 0 })
        #expect(listed.reduce(0) { $0 + $1.residentBytes } == malloc.residentBytes)
        #expect(listed.allSatisfy { $0.residentBytes <= $0.mappedBytes })
    }
}
