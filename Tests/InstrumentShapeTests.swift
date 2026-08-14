@testable import Basset
import BassetECS
import Foundation
import Testing

/// Derived from declaration alone, so these run host-side under `bazel test //...`.
struct InstrumentShapeTests {
    private var instrumentIdSnapshot: [UInt16] {
        InstrumentID.allCases.map(\.rawValue).sorted()
    }

    private var componentIdSnapshot: [UInt16] {
        Component.ID.allCases.map(\.rawValue).sorted()
    }

    private var entityIdSnapshot: [UInt16] {
        Entity.ID.allCases.map(\.rawValue).sorted()
    }

    /// Checked per id, not per registration — an unbuildable instrument still counts.
    @Test func domainMatchesTheFirstSegmentOfEveryName() {
        for id in InstrumentID.allCases {
            let prefix = id.name.split(separator: ".").first.map(String.init)
            #expect(
                prefix == id.domain.rawValue,
                "\(id.name) is filed under \(id.domain.rawValue)"
            )
        }
    }

    @Test func everyNameIsAtLeastDomainAndSubject() {
        for id in InstrumentID.allCases {
            #expect(
                id.name.split(separator: ".").count >= 2,
                "\(id.name) needs a subject after its domain"
            )
        }
    }

    @Test func namesAreUniqueAcrossTheIdSpace() {
        let names = InstrumentID.allCases.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// The top byte is reserved for `basset` reporting on itself — never a requestable instrument.
    @Test func onlyTheBassetDomainLivesInTheReservedBlock() {
        for id in InstrumentID.allCases {
            let reserved = id.rawValue & 0xff00 == 0xff00
            #expect(
                reserved == (id.domain == .basset),
                "\(id.name) is \(reserved ? "in" : "outside") the reserved block but its domain is \(id.domain)"
            )
        }
    }

    /// Registration is unconditional; only the mechanism body is platform-gated.
    /// `basset`'s own domain never gets one — it reports on itself, not on request.
    @Test func everyIdInTheSpaceIsRegistered() {
        let requestable = InstrumentID.allCases.filter { $0.domain != .basset }
        #expect(Set(Instruments.all.map(\.id)) == Set(requestable))
    }

    /// The enum and the registrations are one list read twice, kept in the same order.
    @Test func registrationsAreInWireIdOrder() {
        let ids = Instruments.all.map(\.id.rawValue)
        #expect(ids == ids.sorted())
    }

    @Test func wireIdsAreUniqueAcrossTheCatalog() {
        let ids = Instruments.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func namesAreUniqueAcrossTheCatalog() {
        let names = Instruments.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// Two conformances is two answers — one instrument once suspended every thread.
    @Test func everyInstrumentDeclaresExactlyOneDeliveryClass() {
        for registration in Instruments.all {
            let declared = [
                registration.instrumentType is any Snapshotable.Type,
                registration.instrumentType is any Streamable.Type,
                registration.instrumentType is any Faultable.Type,
            ]
            .filter(\.self)
            .count

            #expect(
                declared == 1,
                "\(registration.name) conforms to \(declared) delivery protocols"
            )
        }
    }

    /// The other half: what the type implements must match what it registered.
    @Test func theRegisteredDeliveryMatchesWhatTheTypeImplements() {
        for registration in Instruments.all {
            switch registration.delivery {
            case .reading:
                #expect(registration.instrumentType is any Snapshotable.Type)
            case .stream:
                #expect(registration.instrumentType is any Streamable.Type)
            case .fault:
                #expect(registration.instrumentType is any Faultable.Type)
            }
        }
    }

    /// A schema an agent reads has to match what the type actually accepts, or it lies.
    @Test func aDeclaredConfigSchemaMatchesWhetherTheTypeIsConfigurable() {
        for registration in Instruments.all {
            let isConfigurable = registration.instrumentType is any Configurable.Type
            let declaresSchema = !registration.id.metadata.config.isEmpty
            #expect(
                isConfigurable == declaresSchema,
                "\(registration.name) is Configurable: \(isConfigurable), schema: \(declaresSchema)"
            )
        }
    }

    /// Proves `defaultConfig` itself decodes cleanly — a bad default would refuse forever.
    @Test func everyRegistrationBuildsWithoutSentConfigBeingRefused() {
        for registration in Instruments.all {
            let (_, refused) = registration.build(nil)
            #expect(!refused, "\(registration.name) refused its own default config")
        }
    }

    /// iOS only — a Mac's major version means nothing to any instrument's floor.
    @Test func noShippedInstrumentNeedsANewerOSThanThisOne() {
        #if os(iOS)
        for registration in Instruments.all {
            #expect(
                registration.availability.minIOS <= Availability.runningMajorVersion,
                "\(registration.name) declares minIOS \(registration.availability.minIOS)"
            )
        }
        #endif
    }

    /// The factory proves delivery at compile time; the id space repeats it for the menu.
    @Test func theIdSpaceAgreesWithTheFactoryOnDelivery() {
        for registration in Instruments.all {
            #expect(
                registration.delivery == registration.id.delivery,
                "\(registration.name): registered \(registration.delivery.rawValue), id space says \(registration.id.delivery.rawValue)"
            )
        }
    }

    /// Grow-only ids — nothing removed or renumbered; duplicates already fail to compile.
    @Test func idSpacesOnlyEverGrow() {
        // Holes are retirements, never reissued (components: see retiredIdsStayReserved).
        let instrumentIds: [UInt16] = Array(1...21) + Array(23...39) + Array(42...54) + [0xff00]
        let componentIds: [UInt16] = Array(1...225)
        let entityIds: [UInt16] = Array(0...32) + Array(35...46) + [0xff00]

        #expect(instrumentIdSnapshot == instrumentIds)
        #expect(componentIdSnapshot == componentIds)
        #expect(entityIdSnapshot == entityIds)
    }
}
