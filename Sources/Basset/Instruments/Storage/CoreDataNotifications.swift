import Foundation

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
