import BassetEntityComponent
import Foundation

/// Core Data churn aggregated per flush window — catches mutations that never reach a save.
final class CoreDataChanges: Streamable, PlainInstrument {
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

    static let id: InstrumentID = .coreDataChanges

    private let tally: Mutex<Tallied> = .init(Tallied())
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
        tally.withLock { $0 = Tallied() }
    }

    /// Runs on the mutating thread: five counts and an increment under a lock, nothing allocated.
    private func count(_ note: Notification) {
        let facts = ManagedObjectContextFacts(context: note.object)
        let inserted = CoreDataNotifications.Change.inserted.count(in: note.userInfo)
        let updated = CoreDataNotifications.Change.updated.count(in: note.userInfo)
        let deleted = CoreDataNotifications.Change.deleted.count(in: note.userInfo)
        let refreshed = CoreDataNotifications.Change.refreshed.count(in: note.userInfo)

        tally.withLock { tally in
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
        tally.withLock { tally -> Tallied? in
            defer { tally = Tallied() }
            return tally.isEmpty ? nil : tally
        }
    }
}

/// String literals, not the framework's symbols — three names aren't what their symbol says.
enum CoreDataNotifications {
    /// userInfo keys are short lowercase words, not the `NS…Key` symbols that name them.
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

            // Counted, not enumerated — touches no property, so nothing here faults an object.
            return (objects as? NSSet)?.count ?? 0
        }
    }

    static let willSave = Notification
        .Name("NSManagingContextWillSaveChangesNotification")
    static let didSave = Notification.Name("NSManagingContextDidSaveChangesNotification")
    static let objectsChanged = Notification
        .Name("NSObjectsChangedInManagingContextNotification")
}

/// What's knowable about a context from its notification alone, without holding or importing it.
struct ManagedObjectContextFacts {
    /// `confinement`/`privateQueue`/`mainQueue` = 0/1/2, read from the framework, not assumed.
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

    /// Only the main-queue case is provable this cheaply; private-queue is left unreported.
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

/// Save duration paired from will-save/did-save — both post on the thread doing the work.
final class CoreDataSave: Streamable, PlainInstrument {
    static let id: InstrumentID = .coreDataSave

    private let clock: Clock = .init()
    /// Keyed by identity, never retaining the context; an unfinished save leaves one stale entry.
    private let started: Mutex<[ObjectIdentifier: MonotonicTime]> = .init([:])
    private var observers: [NSObjectProtocol] = []

    init() {}

    /// Not a pointer into the app — only enough to tell two contexts apart within one capture.
    private static func identity(of object: AnyObject) -> UInt32 {
        UInt32(truncatingIfNeeded: ObjectIdentifier(object).hashValue)
    }

    func observe(_ context: Context) {
        watch(CoreDataNotifications.willSave) { [weak self] note in
            guard let self, let saving = note.object as AnyObject? else {
                return
            }

            let now = self.clock.now()
            self.started.withLock { $0[ObjectIdentifier(saving)] = now }
        }
        watch(CoreDataNotifications.didSave) { [weak self] note in
            self?.report(note, into: context)
        }
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        started.withLock { $0.removeAll() }
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
            // Written only when true, so a `false` on every ordinary save doesn't train it out.
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
        let began = started.withLock { started -> MonotonicTime? in
            defer { started[key] = nil }
            return started[key]
        }
        guard let began else {
            return nil
        }

        return clock.now().nanoseconds &- began.nanoseconds
    }
}
