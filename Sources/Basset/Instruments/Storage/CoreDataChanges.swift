import BassetECS
import Foundation

/// How much a Core Data stack is churning between saves.
///
/// `objectsDidChange` fires on every mutation, not only on the ones that reach
/// disk, so it is the signal for the shape of bug a save count cannot show: a
/// screen that rewrites the same rows on every scroll tick, a merge that touches
/// ten thousand objects, a refresh storm that never persists anything.
///
/// **Aggregated, never transcribed.** The notification is the highest-frequency
/// thing in this domain — a batch import posts thousands a second — and a
/// reading per notification would spend a request's whole budget describing one
/// import. One flush says how many arrived and what they touched in total, with
/// the window they cover, so a rate is the reader's to compute.
final class CoreDataChanges: StreamingInstrument {
    private struct Tallied {
        var notifications: UInt64 = 0
        var inserted = 0
        var updated = 0
        var deleted = 0
        var refreshed = 0
        var sawConfinementViolation = false

        var isEmpty: Bool {
            notifications == 0
        }
    }

    static let id: InstrumentWireID = .coreDataChanges
    static let entity = Entity.WireID.managedObjectContext

    private let lock: NSLock = .init()
    private var tally: Tallied = .init()
    private var observer: NSObjectProtocol?

    init() {}

    private static func write(
        _ taken: Tallied,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.occurrenceCount(taken.notifications))
        out.put(.windowNanoseconds(window.nanoseconds))

        if taken.inserted > 0 {
            out.put(.insertedCount(UInt32(clamping: taken.inserted)))
        }
        if taken.updated > 0 {
            out.put(.updatedCount(UInt32(clamping: taken.updated)))
        }
        if taken.deleted > 0 {
            out.put(.deletedCount(UInt32(clamping: taken.deleted)))
        }
        if taken.refreshed > 0 {
            out.put(.refreshedCount(UInt32(clamping: taken.refreshed)))
        }
        if taken.sawConfinementViolation {
            out.put(.confinementViolation(true))
        }
    }

    func observe(_ context: Context) {
        observer = NotificationCenter.default.addObserver(
            forName: CoreDataNotifications.objectsChanged,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.count(note)
        }

        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self, let taken = self.take() else {
                return
            }

            Self.write(taken, over: window, into: &out)
        }
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        lock.withLock { tally = Tallied() }
    }

    /// Runs on whichever thread mutated the context, so it does the least
    /// possible: five set counts and an increment under a lock. Nothing is
    /// allocated and no managed object is touched.
    private func count(_ note: Notification) {
        let facts = ManagedObjectContextFacts(context: note.object)
        let inserted = CoreDataNotifications.Change.inserted.count(in: note.userInfo)
        let updated = CoreDataNotifications.Change.updated.count(in: note.userInfo)
        let deleted = CoreDataNotifications.Change.deleted.count(in: note.userInfo)
        let refreshed = CoreDataNotifications.Change.refreshed.count(in: note.userInfo)

        lock.withLock {
            tally.notifications += 1
            tally.inserted += inserted
            tally.updated += updated
            tally.deleted += deleted
            tally.refreshed += refreshed
            tally.sawConfinementViolation =
                tally.sawConfinementViolation || facts.isConfinementViolation
        }
    }

    private func take() -> Tallied? {
        lock.withLock { () -> Tallied? in
            defer { tally = Tallied() }
            return tally.isEmpty ? nil : tally
        }
    }
}
