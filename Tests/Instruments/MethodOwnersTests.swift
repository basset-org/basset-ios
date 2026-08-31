@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct MethodOwnersTests {
    @Test func aprocessWithNoWatchedClassLoadedSaysSo() {
        let readings = emit(from: [])

        #expect(rendered(.mechanismStatus, in: readings.first)?.contains("unavailable")
            == true)
    }

    @Test func eachWatchedMethodCarriesItsClassSelectorAndImage() {
        let readings = emit(from: [
            owner("UIViewController", "viewWillAppear:", image: "UIKit", declaring: "UIKit"),
        ])

        #expect(rendered(.methodClass, in: readings.first) == "UIViewController")
        #expect(rendered(.methodName, in: readings.first) == "viewWillAppear:")
        #expect(rendered(.imageName, in: readings.first) == "UIKit")
    }

    /// The pairing is the finding — either half alone says nothing; overriding elsewhere is fine.
    @Test func animplementationFromAnotherImageIsMarked() {
        let readings = emit(from: [
            owner("UIViewController", "viewWillAppear:", image: "UIKit", declaring: "UIKit"),
            owner("UIApplication", "sendEvent:", image: "Analytics", declaring: "UIKit"),
        ])

        let flags = readings.compactMap { rendered(.ownedByDeclaringImage, in: $0) }
        #expect(flags == ["true", "false"])
    }

    /// An address in no mapped image is a runtime trampoline, not readable as "the class's own".
    @Test func animplementationInNoImageIsNeitherMappedNorItsOwn() {
        let replaced = owner("UIWindow", "makeKeyAndVisible", image: "", declaring: "")

        #expect(replaced.isInMappedImage == false)
        #expect(replaced.isDeclaringImage == false)
    }

    /// End to end — a runtime-replaced method carries no image, and the reading says so plainly.
    @Test func areplacedMethodIsReportedAsInNoMappedImage() {
        let readings = emit(from: [
            owner("UIApplication", "sendEvent:", image: "", declaring: "UIKit"),
        ])

        #expect(rendered(.implementationInMappedImage, in: readings.first) == "false")
        #expect(rendered(.imageName, in: readings.first) == nil)
    }

    private func emit(from owners: [MethodOwners.Owner]) -> [Entity] {
        var out = Readings(.method)
        MethodOwners.write(owners, into: &out)
        guard !out.isEmpty else {
            return []
        }

        return [out.build()] + out.additionalEntities()
    }

    private func owner(
        _ className: String,
        _ selector: String,
        image: String,
        declaring: String
    ) -> MethodOwners.Owner {
        MethodOwners.Owner(
            className: className,
            selector: selector,
            image: image,
            declaringImage: declaring
        )
    }

    private func rendered(_ id: Component.ID, in entity: Entity?) -> String? {
        entity?.components.first { $0.known == id }?.value.rendered
    }
}

struct MethodOwnersWiringTests {
    @Test func itIsRegisteredAsAReadingFromTheRuntimeDomain() throws {
        let registration = try #require(
            Instruments.all.first { $0.id == .methodOwners }
        )

        #expect(registration.name == "runtime.methodOwners")
        #expect(registration.domain == .runtime)
        #expect(registration.delivery == .reading)
    }

    /// Activates the whole catalog first — any hook on a watched selector fails this, even later.
    @Test func noWatchedMethodResolvesToBassetsOwnImage() throws {
        let runner = try InstrumentRunner(
            instruments: Instruments.all,
            opener: SilentOpener(),
            atLaunchRequests: AtLaunchRequests(
                storage: #require(UserDefaults(suiteName: "basset-tests-\(UUID().uuidString)"))
            )
        )
        runner.converge(
            to: [
                BassetRequest(
                    requestId: 1,
                    instruments: Instruments.all.map(\.name),
                    atLaunch: false,
                    expiresAt: Date().addingTimeInterval(600),
                    maxFrames: nil,
                    requestToken: "token"
                ),
            ],
            ingestEndpoint: "in"
        )
        runner.settle()
        // Catalog instruments stay installed until withdrawn, competing with each other suite.
        defer {
            runner.converge(to: [], ingestEndpoint: "in")
            runner.settle()
        }

        // Not "resolves to basset's image" — `imp_implementationWithBlock` resolves to no image.
        for owner in MethodOwners.read(MethodOwners.watched) {
            #expect(
                owner.isInMappedImage,
                "\(owner.className) \(owner.selector) was replaced at runtime"
            )
        }
    }

    /// `NSObject` exists on every platform the library builds for, so this runs on host too.
    @Test func arealMethodResolvesToTheImageHoldingIt() throws {
        let owners = MethodOwners.read([
            (className: "NSObject", selector: "forwardInvocation:"),
        ])

        let resolved = try #require(owners.first)
        #expect(resolved.image.isEmpty == false, "dladdr named the implementation")
        #expect(resolved.declaringImage.isEmpty == false, "the class named its image")
    }

    @Test func aclassThatIsNotLoadedIsAbsentRatherThanBlank() {
        let owners = MethodOwners.read([
            (className: "NoSuchClassExistsHere", selector: "doesNotMatter"),
        ])

        #expect(owners.isEmpty)
    }
}

private final class SilentOpener: TransportOpener, @unchecked Sendable {
    func open(request _: BassetRequest, ingestEndpoint _: String) -> Transport? {
        nil
    }
}
