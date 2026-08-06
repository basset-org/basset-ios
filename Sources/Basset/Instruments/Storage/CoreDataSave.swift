import BassetECS
import Foundation

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
