@testable import Basset
import Foundation
import Testing

/// The values these constants carry are not the names of the symbols that hold
/// them, and nothing in the type system says so. Pinning them here means a
/// well-meaning "tidy-up" that derives the string from the symbol name fails a
/// test rather than silently subscribing to three names nothing ever posts.
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

    /// The order is not the one the names suggest: confinement is zero and main
    /// is two, so a mapping written from intuition marks every private-queue
    /// context as main and reports confinement violations that did not happen.
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

    /// Core Data hands over a set of managed objects. Anything else in that slot
    /// is not counted rather than crashed on.
    @Test func somethingThatIsNotASetCountsAsNothing() {
        #expect(CoreDataNotifications.Change.deleted.count(in: ["deleted": "seven"]) == 0)
    }
}

struct ConfinementViolationTests {
    /// Stands in for a managed object context by answering the one selector the
    /// facts are read through — which is also proof that the read works against
    /// a class basset knows nothing about.
    private final class Probe: NSObject {
        @objc let concurrencyType: UInt

        init(concurrencyType: UInt) {
            self.concurrencyType = concurrencyType
        }
    }

    /// The one case that is certain. Everything else is either fine or not
    /// cheaply provable, and guessing at the second would report a violation
    /// against an app that has none.
    @Test func aMainQueueContextUsedOffTheMainThreadIsTheOnlyCertainViolation() {
        #expect(facts(.mainQueue, onMainThread: false).isConfinementViolation)
        #expect(facts(.mainQueue, onMainThread: true).isConfinementViolation == false)
    }

    /// A private-queue context runs on whatever thread its queue picks, so it is
    /// off the main thread by design and must never be reported for it.
    @Test func aPrivateQueueContextIsNeverReportedForRunningOffMain() {
        #expect(facts(.privateQueue, onMainThread: false).isConfinementViolation == false)
        #expect(facts(.privateQueue, onMainThread: true).isConfinementViolation == false)
    }

    @Test func aContextThatWillNotSayWhatItIsIsNotAccused() {
        let unknown = ManagedObjectContextFacts(context: nil, onMainThread: false)

        #expect(unknown.concurrency == nil)
        #expect(unknown.isConfinementViolation == false)
    }

    /// The concurrency type is read through the runtime, so an object that has no
    /// such property must answer nothing rather than raise.
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
