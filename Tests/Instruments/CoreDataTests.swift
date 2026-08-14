@testable import Basset
import Foundation
import Testing

/// Pins the raw notification strings so a "tidy-up" deriving them from symbol names fails loudly.
struct CoreDataNotificationNameTests {
    @Test func theSaveNotificationsCarryTheirLegacyNames() {
        #expect(
            CoreDataNotifications.willSave.rawValue
                == "NSManagingContextWillSaveChangesNotification"
        )
        #expect(
            CoreDataNotifications.didSave.rawValue
                == "NSManagingContextDidSaveChangesNotification"
        )
        #expect(
            CoreDataNotifications.objectsChanged.rawValue
                == "NSObjectsChangedInManagingContextNotification"
        )
    }

    @Test func theChangeKeysAreShortLowercaseWordsRatherThanTheirSymbols() {
        #expect(CoreDataNotifications.Change.inserted.rawValue == "inserted")
        #expect(CoreDataNotifications.Change.updated.rawValue == "updated")
        #expect(CoreDataNotifications.Change.deleted.rawValue == "deleted")
        #expect(CoreDataNotifications.Change.refreshed.rawValue == "refreshed")
        #expect(CoreDataNotifications.Change.invalidated.rawValue == "invalidated")
    }

    /// Confinement is 0, main is 2 — an intuitive mapping misreports every private-queue context.
    @Test func theConcurrencyTypesAreNumberedTheWayCoreDataNumbersThem() {
        #expect(ManagedObjectContextFacts.Concurrency.confinement.rawValue == 0)
        #expect(ManagedObjectContextFacts.Concurrency.privateQueue.rawValue == 1)
        #expect(ManagedObjectContextFacts.Concurrency.mainQueue.rawValue == 2)
    }

    @Test func aCountIsZeroWhenTheKeyIsAbsentRatherThanFailing() {
        #expect(CoreDataNotifications.Change.inserted.count(in: nil) == 0)
        #expect(CoreDataNotifications.Change.inserted
            .count(in: ["updated": NSSet()]) == 0)
        #expect(
            CoreDataNotifications.Change.updated
                .count(in: ["updated": NSSet(array: [1, 2, 3])]) == 3
        )
    }

    /// Anything other than a set in that slot is not counted rather than crashed on.
    @Test func somethingThatIsNotASetCountsAsNothing() {
        #expect(CoreDataNotifications.Change.deleted.count(in: ["deleted": "seven"]) == 0)
    }
}

struct ConfinementViolationTests {
    /// Answers the one selector the facts read through — proof it works against an unknown class.
    private final class Probe: NSObject {
        @objc let concurrencyType: UInt

        init(concurrencyType: UInt) {
            self.concurrencyType = concurrencyType
        }
    }

    /// The one certain case — guessing at the rest would accuse apps that have no violation.
    @Test func aMainQueueContextUsedOffTheMainThreadIsTheOnlyCertainViolation() {
        #expect(facts(.mainQueue, onMainThread: false).isConfinementViolation)
        #expect(facts(.mainQueue, onMainThread: true).isConfinementViolation == false)
    }

    /// A private-queue context is off the main thread by design and must never be reported for it.
    @Test func aPrivateQueueContextIsNeverReportedForRunningOffMain() {
        #expect(facts(.privateQueue, onMainThread: false).isConfinementViolation == false)
        #expect(facts(.privateQueue, onMainThread: true).isConfinementViolation == false)
    }

    @Test func aContextThatWillNotSayWhatItIsIsNotAccused() {
        let unknown = ManagedObjectContextFacts(context: nil, onMainThread: false)

        #expect(unknown.concurrency == nil)
        #expect(unknown.isConfinementViolation == false)
    }

    /// Read through the runtime — an object with no such property answers nothing, not raises.
    @Test func anObjectWithNoConcurrencyTypeAnswersNothing() {
        let facts = ManagedObjectContextFacts(context: NSObject(), onMainThread: true)

        #expect(facts.concurrency == nil)
    }

    private func facts(
        _ concurrency: ManagedObjectContextFacts.Concurrency,
        onMainThread: Bool
    ) -> ManagedObjectContextFacts {
        ManagedObjectContextFacts(
            context: Probe(concurrencyType: concurrency.rawValue),
            onMainThread: onMainThread
        )
    }
}
