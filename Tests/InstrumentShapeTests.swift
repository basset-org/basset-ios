@testable import Basset
import BassetECS
import Foundation
import Testing

/// What every instrument gets for free, derived from its declaration. These run
/// on the host: no simulator, so they land in `bazel test //...`.
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

    /// Over every id rather than every registration, so an instrument that does
    /// not compile on this platform is still held to the rule.
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

    /// The catalog is the whole id space on every platform. An instrument whose
    /// framework is absent still registers — only its mechanism body is
    /// conditional — so the emitted menu is the same wherever it is generated,
    /// and `Constraints` rather than compilation decides what can run.
    @Test func everyIdInTheSpaceIsRegistered() {
        #expect(Set(Instruments.all.map(\.id)) == Set(InstrumentID.allCases))
    }

    /// The catalog and the id space are one list read twice: the enum in
    /// declaration order, the registrations beside it. Held in the same order so
    /// a reader can compare them by eye and an addition appends to both ends.
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

    /// Delivery is decided by the factory that accepted the type, and a second
    /// conformance is a second answer to the same question. `runtime.threadSnapshot`
    /// was registered `.fault` and also implemented `reading`, so activating it
    /// suspended every thread in the process before anything had gone wrong —
    /// invisible in the menu, which promised faults only.
    @Test func everyInstrumentDeclaresExactlyOneDeliveryClass() {
        for registration in Instruments.all {
            let declared = [
                registration.instrumentType is any SnapshotInstrument.Type,
                registration.instrumentType is any StreamingInstrument.Type,
                registration.instrumentType is any FaultInstrument.Type,
            ]
            .filter(\.self)
            .count

            #expect(
                declared == 1,
                "\(registration.name) conforms to \(declared) delivery protocols"
            )
        }
    }

    /// The other half of the same rule: what the type implements has to be what
    /// the registration claims.
    @Test func theRegisteredDeliveryMatchesWhatTheTypeImplements() {
        for registration in Instruments.all {
            switch registration.delivery {
            case .reading:
                #expect(registration.instrumentType is any SnapshotInstrument.Type)
            case .stream:
                #expect(registration.instrumentType is any StreamingInstrument.Type)
            case .fault:
                #expect(registration.instrumentType is any FaultInstrument.Type)
            }
        }
    }

    /// The OS half only. A hardware instrument declaring `simulator: false` is
    /// correctly in the catalog and correctly unavailable on a simulator, so
    /// full availability is not a catalog invariant.
    @Test func noShippedInstrumentNeedsANewerOSThanThisOne() {
        for registration in Instruments.all {
            #expect(
                registration.availability.minIOS <= Availability.runningMajorVersion,
                "\(registration.name) declares minIOS \(registration.availability.minIOS)"
            )
        }
    }

    /// The registration factory proves delivery at compile time; the id space
    /// carries it again so the menu can read it without an instrument. They have
    /// to agree.
    @Test func theIdSpaceAgreesWithTheFactoryOnDelivery() {
        for registration in Instruments.all {
            #expect(
                registration.delivery == registration.id.delivery,
                "\(registration.name): registered \(registration.delivery.rawValue), id space says \(registration.id.delivery.rawValue)"
            )
        }
    }

    /// The ids are grow-only, so this asserts an absence: no case was removed
    /// and no case was renumbered. Duplicates are already a compile error.
    @Test func idSpacesOnlyEverGrow() {
        // 22 is a hole and stays one. It held `lifecycle.exit`, the only MetricKit
        // instrument, retired in favour of `lifecycle.lastRunEnded`. A retired id
        // is never reissued, so the gap is the record of that rather than a
        // mistake to tidy up.
        #expect(instrumentIdSnapshot == Array(1...21) + Array(23...48))
        #expect(componentIdSnapshot == Array(1...194))
        #expect(entityIdSnapshot == Array(0...41))
    }
}
