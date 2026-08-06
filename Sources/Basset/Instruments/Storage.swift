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

/// Core Data's notification vocabulary, by value.
///
/// **basset does not import CoreData.** `NotificationCenter` matches on a name,
/// and a name is a string. Importing the framework for its constants would link
/// CoreData into every app's binary and destroy the one thing worth knowing for
/// free — that an app posting none of these does not use Core Data at all.
///
/// **Three of these names are not what their symbols are called**, and the
/// difference is invisible until nothing ever fires. `NSManagedObjectContext`​
/// `DidSaveNotification` carries the value
/// `NSManagingContextDidSaveChangesNotification`; will-save and
/// objects-did-change are renamed the same way. Deriving the string from the
/// symbol subscribes to three names nothing posts, and the instrument reports
/// silence for an app saving thousands of times a second.
///
/// Every value here was read out of the framework at runtime rather than copied
/// from a header, which is the only way to be right about it.
enum CoreDataNotifications {
    /// The userInfo keys are short lowercase words rather than the `NS…Key`
    /// symbols that name them.
    enum Change: String, CaseIterable {
        case inserted
        case updated
        case deleted
        case refreshed
        case invalidated

        func count(in userInfo: [AnyHashable: Any]?) -> Int {
            guard let objects = userInfo?[rawValue] else {
                return 0
            }

            // A set of managed objects, counted and never enumerated. Counting
            // touches no property, so nothing here fires a fault — which is the
            // whole reason this instrument can watch a Core Data app without
            // becoming its performance problem.
            return (objects as? NSSet)?.count ?? 0
        }
    }

    static let willSave = Notification
        .Name("NSManagingContextWillSaveChangesNotification")
    static let didSave = Notification.Name("NSManagingContextDidSaveChangesNotification")
    static let objectsChanged = Notification
        .Name("NSObjectsChangedInManagingContextNotification")
}

/// What can be learned about the context that posted a notification without
/// holding on to it, importing its framework, or touching a managed object.
struct ManagedObjectContextFacts {
    /// `confinement`, `privateQueue` and `mainQueue` are 0, 1 and 2 — read from
    /// the framework rather than assumed, because the order is not the one the
    /// names suggest.
    enum Concurrency: UInt, CaseIterable {
        case confinement = 0
        case privateQueue = 1
        case mainQueue = 2

        var name: String {
            switch self {
            case .confinement: "confinement"
            case .privateQueue: "privateQueue"
            case .mainQueue: "mainQueue"
            }
        }
    }

    private static let selector: Selector = .init("concurrencyType")

    let concurrency: Concurrency?
    let onMainThread: Bool

    /// A main-queue context being used off the main thread is a **certain**
    /// confinement violation with no false positives, and it is readable here
    /// because the notification is posted on the thread that did the work.
    ///
    /// The private-queue half is not provable this cheaply — a private-queue
    /// context is entitled to run on any thread its queue picks — so it is left
    /// unreported rather than guessed at. `-com.apple.CoreData.ConcurrencyDebug`
    /// answers it and does so by crashing the process, which is not a trade a
    /// diagnostic tool gets to make on the app's behalf.
    var isConfinementViolation: Bool {
        concurrency == .mainQueue && !onMainThread
    }

    init(context: Any?, onMainThread: Bool = Thread.isMainThread) {
        self.onMainThread = onMainThread
        concurrency = Self.concurrency(of: context)
    }

    private static func concurrency(of context: Any?) -> Concurrency? {
        guard let object = context as AnyObject?,
              object.responds(to: selector),
              let raw = object.value(forKey: "concurrencyType") as? UInt
        else {
            return nil
        }

        return Concurrency(rawValue: raw)
    }
}

/// Every Core Data save: how long it took, how much it wrote, and whether it
/// happened on the thread its context is confined to.
///
/// **No interception at all.** `NotificationCenter` delivers these regardless of
/// who created the context or when, so an app's own persistence stack is visible
/// without basset knowing anything about it — which is why `storage` is not a
/// swizzling domain.
///
/// The save is timed by pairing will-save with did-save on the same context. Both
/// are posted on the thread doing the work, so the duration is the save's own and
/// the thread the pair arrives on is the thread the app used.
final class CoreDataSave: StreamingInstrument {
    static let id: InstrumentWireID = .coreDataSave
    static let entity = Entity.WireID.managedObjectContext

    private let clock: Clock = .init()
    private let lock: NSLock = .init()
    /// Keyed by the context's identity and holding only a time. The context
    /// itself is never retained — basset does not keep an app object alive, and a
    /// save that never completes leaves one stale entry rather than a leak.
    private var started: [ObjectIdentifier: MonotonicTime] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {}

    /// Which context, without saying anything about it. An address would be a
    /// pointer into the app; this is only enough to tell two contexts apart
    /// within one capture.
    private static func identity(of object: AnyObject) -> UInt32 {
        UInt32(truncatingIfNeeded: ObjectIdentifier(object).hashValue)
    }

    func observe(_ context: Context) {
        watch(CoreDataNotifications.willSave) { [weak self] note in
            guard let self, let saving = note.object as AnyObject? else {
                return
            }

            let now = self.clock.now()
            self.lock.withLock { self.started[ObjectIdentifier(saving)] = now }
        }
        watch(CoreDataNotifications.didSave) { [weak self] note in
            self?.report(note, into: context)
        }
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        lock.withLock { started.removeAll() }
    }

    private func watch(
        _ name: Notification.Name,
        _ body: @escaping (Notification) -> Void
    ) {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { note in
                body(note)
            }
        )
    }

    private func report(_ note: Notification, into context: Context) {
        let facts = ManagedObjectContextFacts(context: note.object)
        let elapsed = elapsed(for: note.object)
        let counts = CoreDataNotifications.Change.allCases.map { change in
            (change, change.count(in: note.userInfo))
        }

        context.emit { out in
            for (change, count) in counts {
                switch change {
                case .inserted: out.put(.insertedCount(UInt32(count)))
                case .updated: out.put(.updatedCount(UInt32(count)))
                case .deleted: out.put(.deletedCount(UInt32(count)))
                case .invalidated,
                     .refreshed: continue
                }
            }
            if let elapsed {
                out.put(.totalNanoseconds(elapsed))
            }
            if let concurrency = facts.concurrency {
                out.put(.contextConcurrency(concurrency.name))
            }
            // Written only when true. An explicit `false` on every ordinary save
            // trains a reader to skip the column that matters.
            if facts.isConfinementViolation {
                out.put(.confinementViolation(true))
            }
            if let saving = note.object as AnyObject? {
                out.put(.instanceId(Self.identity(of: saving)))
            }
        }
    }

    private func elapsed(for saving: Any?) -> UInt64? {
        guard let saving = saving as AnyObject? else {
            return nil
        }

        let key = ObjectIdentifier(saving)
        let began = lock.withLock { () -> MonotonicTime? in
            defer { started[key] = nil }
            return started[key]
        }
        guard let began else {
            return nil
        }

        return clock.now().nanoseconds &- began.nanoseconds
    }
}
