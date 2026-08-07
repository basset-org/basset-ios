@testable import Basset
import BassetECS
import Foundation
import Testing

struct CloudKitEventTests {
    /// The values were read out of the framework rather than assumed, and an
    /// unrecognised one keeps its number — a fourth event type must not be
    /// silently named after the third.
    @Test func eventTypesCarryTheNumbersCloudKitUses() {
        #expect(SyncEvent.name(ofType: 0) == "setup")
        #expect(SyncEvent.name(ofType: 1) == "import")
        #expect(SyncEvent.name(ofType: 2) == "export")
        #expect(SyncEvent.name(ofType: 7) == "unrecognised(7)")
    }

    /// An event still running and an event that failed are opposite findings, and
    /// both have `succeeded == false`. The missing end date is what separates
    /// them.
    @Test func anEventStillRunningIsNotReportedAsAFailure() {
        var running = readings()
        CloudKitEvents.write(
            SyncEvent(type: "import", succeeded: false, startedAt: Date(), endedAt: nil),
            into: &running
        )

        var failed = readings()
        CloudKitEvents.write(
            SyncEvent(
                type: "import",
                succeeded: false,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 1),
                error: NSError(domain: "CKErrorDomain", code: 25)
            ),
            into: &failed
        )

        #expect(rendered(running.sealed(), .mechanismStatus) == "still running")
        #expect(failed.componentsWritten.contains(.mechanismStatus) == false)
        #expect(rendered(failed.sealed(), .errorCode) == "25")
    }

    /// The whole reason the domain exists: a CKError says whether the user is
    /// signed out or out of storage, which is not the app's bug.
    @Test func theErrorIsCarriedAsItsDomainAndCode() {
        var out = readings()
        CloudKitEvents.write(
            SyncEvent(
                type: "export",
                succeeded: false,
                error: NSError(domain: "CKErrorDomain", code: 9)
            ),
            into: &out
        )

        #expect(rendered(out.sealed(), .errorDomain) == "CKErrorDomain")
        #expect(rendered(out.sealed(), .errorCode) == "9")
    }

    @Test func anEventThisBuildCannotReadIsSaidRatherThanGuessedAt() {
        var out = readings()
        CloudKitEvents.write(SyncEvent(type: nil, succeeded: nil), into: &out)

        #expect(out.componentsWritten == [.mechanismStatus])
    }

    /// Read through the runtime, so an object that is not an event must produce a
    /// reading rather than raise — `value(forKey:)` on a missing key throws an
    /// ObjC exception Swift cannot catch.
    @Test func somethingThatIsNotAnEventIsSurvived() {
        #expect(SyncEvent(NSObject()).type == nil)
        #expect(SyncEvent(nil).type == nil)
    }

    private func readings() -> Readings {
        Readings(
            entity: .cloudSync,
            instrumentName: "sync.cloudKit.events"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}

struct KeyValueStoreSyncTests {
    @Test func changeReasonsCarryTheNumbersTheStoreUses() {
        #expect(KeyValueStoreSync.name(ofReason: 0) == "serverChange")
        #expect(KeyValueStoreSync.name(ofReason: 1) == "initialSync")
        #expect(KeyValueStoreSync.name(ofReason: 2) == "quotaViolation")
        #expect(KeyValueStoreSync.name(ofReason: 3) == "accountChange")
        #expect(KeyValueStoreSync.name(ofReason: 9) == "unrecognised(9)")
    }

    /// The one the instrument exists for: past 1 MB or 1024 keys the store stops
    /// syncing and says nothing else, ever.
    @Test func aQuotaViolationIsReportedByName() {
        var out = readings()
        KeyValueStoreSync.write(
            [KeyValueStoreSync.reasonKey: NSNumber(value: 2)],
            into: &out
        )

        #expect(rendered(out.sealed(), .changeReason) == "quotaViolation")
    }

    /// The count, never the keys. A key name is the app's own vocabulary and
    /// routinely carries a user's identifiers in it.
    @Test func changedKeysAreCountedAndNeverNamed() {
        var out = readings()
        KeyValueStoreSync.write(
            [
                KeyValueStoreSync.reasonKey: NSNumber(value: 0),
                KeyValueStoreSync.changedKeysKey: ["user.4821.token", "lastSeen"],
            ],
            into: &out
        )

        #expect(rendered(out.sealed(), .changedKeyCount) == "2")
        let rendered = out.sealed().components.map(\.value.rendered).joined()
        #expect(rendered.contains("4821") == false)
    }

    @Test func aChangeWithNoStatedReasonIsSaidRatherThanInvented() {
        var out = readings()
        KeyValueStoreSync.write(nil, into: &out)

        #expect(rendered(out.sealed(), .changeReason) == "unstated")
        #expect(out.componentsWritten.contains(.mechanismStatus))
    }

    private func readings() -> Readings {
        Readings(
            entity: .keyValueStore,
            instrumentName: "sync.keyValueStore"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
