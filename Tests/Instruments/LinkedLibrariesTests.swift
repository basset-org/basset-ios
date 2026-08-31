@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct LinkedLibrariesTests {
    /// A stand-in app bundle so fixtures don't depend on where the test binary lives.
    private static let shipped = "/somewhere/Example.app"

    @Test func aprocessWithNoImagesSaysTheMechanismFailed() {
        let readings = emit(from: [])

        #expect(rendered(.mechanismStatus, in: readings.first)?.contains("unavailable")
            == true)
        #expect(readings.count == 1)
    }

    /// No dependencies of its own is a real answer, not absent — the total shows what's mapped.
    @Test func anappShippingNothingStillReportsTheTotal() {
        let readings = emit(from: [system("UIKit"), system("Foundation")])

        #expect(count(.occurrenceCount, in: readings.first) == 2)
        #expect(count(.bundledImageCount, in: readings.first) == 0)
        #expect(rendered(.imageName, in: readings.first) == nil)
    }

    @Test func onlyTheImagesTheAppShippedAreNamed() {
        let readings = emit(from: [
            system("UIKit"),
            bundled("Analytics", size: 100),
            system("Foundation"),
            bundled("Networking", size: 200),
        ])

        let named = readings.compactMap { rendered(.imageName, in: $0) }
        #expect(named == ["Networking", "Analytics"], "largest first, system omitted")
    }

    /// Both counts ride on every row so a reader taking one image still learns the total.
    @Test func everyRowCarriesBothCounts() {
        let readings = emit(from: [
            system("UIKit"),
            bundled("Analytics", size: 100),
            bundled("Networking", size: 200),
        ])

        for reading in readings where rendered(.imageName, in: reading) != nil {
            #expect(count(.occurrenceCount, in: reading) == 3)
            #expect(count(.bundledImageCount, in: reading) == 2)
        }
    }

    @Test func thelargestShippedFrameworkLeads() {
        let readings = emit(from: [
            bundled("Small", size: 10),
            bundled("Large", size: 900),
            bundled("Middle", size: 400),
        ])

        #expect(rendered(.imageName, in: readings.first) == "Large")
        #expect(count(.imageTextBytes, in: readings.first) == 900)
    }

    @Test func morethanTheCeilingReportsTheTruncation() {
        let many = (0 ..< (LinkedLibraries.ceiling + 5)).map {
            bundled("Framework\($0)", size: UInt64($0))
        }

        let readings = emit(from: many)

        let truncation = readings
            .compactMap { rendered(.mechanismStatus, in: $0) }
            .first { $0.hasPrefix("truncated") }
        #expect(truncation == "truncated: 5 more")
        #expect(readings.filter { rendered(.imageName, in: $0) != nil }.count
            == LinkedLibraries.ceiling)
    }

    /// A full path names install directories — only the file name is emitted.
    @Test func nopathReachesTheReading() {
        let readings = emit(from: [bundled("Analytics", size: 1)])

        let values = readings.flatMap(\.components).map(\.value.rendered)
        #expect(values.contains { $0.contains("/") } == false)
    }

    private func emit(from images: [BinaryImage]) -> [Entity] {
        var out = Readings(.binaryImage)
        LinkedLibraries.write(images, inAppBundleUnder: Self.shipped, into: &out)
        guard !out.isEmpty else {
            return []
        }

        return [out.build()] + out.additionalEntities()
    }

    private func bundled(_ name: String, size: UInt64) -> BinaryImage {
        BinaryImage(
            name: name,
            loadAddress: 0x1000,
            size: size,
            uuid: "uuid-\(name)",
            isMainExecutable: false,
            path: "\(Self.shipped)/Frameworks/\(name).framework/\(name)"
        )
    }

    private func system(_ name: String) -> BinaryImage {
        BinaryImage(
            name: name,
            loadAddress: 0x2000,
            size: 1,
            uuid: "uuid-\(name)",
            isMainExecutable: false,
            path: "/System/Library/Frameworks/\(name).framework/\(name)"
        )
    }

    private func rendered(_ id: Component.ID, in entity: Entity?) -> String? {
        entity?.components.first { $0.known == id }?.value.rendered
    }

    private func count(_ id: Component.ID, in entity: Entity?) -> UInt64? {
        rendered(id, in: entity).flatMap(UInt64.init)
    }
}

struct LinkedLibrariesWiringTests {
    @Test func itIsRegisteredAsAReadingFromTheRuntimeDomain() throws {
        let registration = try #require(
            Instruments.all.first { $0.id == .linkedLibraries }
        )

        #expect(registration.name == "runtime.linkedLibraries")
        #expect(registration.domain == .runtime)
        #expect(registration.delivery == .reading)
    }

    /// Against the real process, not fixtures — dyld answers and names the main executable.
    @Test func thereAlProcessAnswers() {
        let out = LinkedLibraries().reading()

        let rendered = out.build()
            .components
            .first { $0.known == .occurrenceCount }?
            .value
            .rendered
        let total = rendered.flatMap { UInt64($0) } ?? 0
        #expect(total > 1, "a real process maps more than one image")
    }

    /// A classification that can't call the main executable "shipped" is anchored wrong.
    @Test func themainExecutableCountsAsShipped() throws {
        let executable = try #require(BinaryImages.mainExecutable())

        #expect(executable.isInAppBundle(under: BinaryImages.appBundleDirectory()))
    }

    /// `Name.appex` shares the app's path as a text prefix but sits beside it, not inside it.
    @Test func asiblingBundleSharingThePrefixIsNotShipped() {
        let extensionImage = BinaryImage(
            name: "Widget",
            loadAddress: 0x3000,
            size: 1,
            uuid: "uuid-widget",
            isMainExecutable: true,
            path: "/somewhere/Example.appex/Widget"
        )

        #expect(extensionImage.isInAppBundle(under: "/somewhere/Example.app") == false)
    }

    @Test func thedirectoryItselfCountsAsShipped() {
        let executable = BinaryImage(
            name: "Example",
            loadAddress: 0x1000,
            size: 1,
            uuid: "uuid",
            isMainExecutable: true,
            path: "/somewhere/Example.app"
        )

        #expect(executable.isInAppBundle(under: "/somewhere/Example.app"))
    }

    /// A macOS bundle breaks the parent-directory rule — frameworks sit beside the executable.
    @Test(arguments: [
        ("/x/Example.app/Example", "/x/Example.app"),
        ("/x/Example.app/Contents/MacOS/Example", "/x/Example.app"),
        ("/x/Tests.xctest/Contents/MacOS/Tests", "/x/Tests.xctest"),
        ("/usr/local/bin/tool", "/usr/local/bin"),
    ])
    func thebundleRootIsFoundForEveryLayout(_ layout: (String, String)) {
        #expect(BinaryImages.bundleRoot(of: layout.0) == layout.1)
    }

    /// End to end — a framework beside the executable's directory still counts as shipped.
    @Test func amacOSFrameworkSiblingIsShipped() {
        let root = BinaryImages.bundleRoot(of: "/x/Example.app/Contents/MacOS/Example")
        let framework = BinaryImage(
            name: "Analytics",
            loadAddress: 0x1000,
            size: 1,
            uuid: "uuid",
            isMainExecutable: false,
            path: "/x/Example.app/Contents/Frameworks/Analytics.framework/Analytics"
        )

        #expect(framework.isInAppBundle(under: root))
    }

    @Test func anemptyDirectoryShipsNothing() throws {
        let executable = try #require(BinaryImages.mainExecutable())

        #expect(executable.isInAppBundle(under: "") == false)
    }

    /// Runs against the real process — the cases above covered only the transform, not discovery.
    @Test func exactlyOneMappedImageIsTheExecutable() {
        #expect(BinaryImages.loaded().filter(\.isMainExecutable).count == 1)
    }

    @Test func theshippedDirectoryIsTheOneHoldingTheExecutable() throws {
        let executable = try #require(BinaryImages.mainExecutable())

        #expect(executable.isInAppBundle(under: BinaryImages.appBundleDirectory()))
    }

    /// A wrong directory would count OS libraries as the app's and drop the app's own binary.
    @Test func theexecutableIsAmongTheImagesItsOwnProcessShipped() throws {
        let executable = try #require(BinaryImages.mainExecutable())
        var out = Readings(.binaryImage)
        LinkedLibraries.write(
            BinaryImages.loaded(),
            inAppBundleUnder: BinaryImages.appBundleDirectory(),
            into: &out
        )
        let readings = [out.build()] + out.additionalEntities()

        #expect(readings.contains { reading in
            reading.components.contains {
                $0.known == .imageName && $0.value.rendered == executable.name
            }
        })
    }
}
