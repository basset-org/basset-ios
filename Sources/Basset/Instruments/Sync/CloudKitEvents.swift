import BassetECS
import Foundation

/// What `NSPersistentCloudKitContainer` is doing, and when it stops working.
///
/// **Most sync failures are not the app's bug** — the user is signed out of
/// iCloud, or their storage is full — and from inside the app those look
/// identical to a sync that is merely slow. One reading settles it before anyone
/// reads a stack trace.
///
/// Needs nothing from the app: the container posts these whoever created it,
/// reached **by notification name, without importing CoreData.** Importing it
/// would put CoreData in every app's binary and destroy the finding that an app
/// posting none of these does not sync at all.
final class CloudKitEvents: StreamingInstrument {
    static let id: InstrumentWireID = .cloudKitEvents
    static let entity = Entity.WireID.cloudSync

    static let notification = Notification
        .Name("NSPersistentCloudKitContainerEventChangedNotification")
    /// The userInfo key is the short word rather than the long symbol that names
    /// it, exactly as Core Data's change keys are.
    static let eventKey = "event"

    private var observer: NSObjectProtocol?

    init() {}

    static func write(_ event: SyncEvent, into out: inout Readings) {
        guard let type = event.type else {
            out
                .put(
                    .mechanismStatus(
                        "a sync event arrived in a shape this build cannot read"
                    )
                )
            return
        }

        out.put(.syncEventType(type))
        // An event with no end date is one still running. Reported as not yet
        // succeeded rather than as failed: an import in progress and an import
        // that failed are opposite findings.
        out.put(.syncSucceeded(event.succeeded ?? false))
        if event.endedAt == nil {
            out.put(.mechanismStatus("still running"))
        }
        if let duration = event.durationNanoseconds {
            out.put(.totalNanoseconds(duration))
        }
        if let error = event.error {
            out.put(.errorDomain(error.domain))
            out.put(.errorCode(Int32(truncatingIfNeeded: error.code)))
        }
    }

    func observe(_ context: Context) {
        observer = NotificationCenter.default.addObserver(
            forName: Self.notification,
            object: nil,
            queue: nil
        ) { note in
            context.emit { out in
                Self.write(SyncEvent(note.userInfo?[Self.eventKey]), into: &out)
            }
        }
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}

/// One `NSPersistentCloudKitContainer.Event`, read through the runtime rather
/// than through the type, so nothing here links CoreData.
struct SyncEvent {
    let type: String?
    let succeeded: Bool?
    let startedAt: Date?
    let endedAt: Date?
    let error: NSError?

    var durationNanoseconds: UInt64? {
        guard let startedAt, let endedAt else {
            return nil
        }

        let seconds = endedAt.timeIntervalSince(startedAt)
        guard seconds >= 0 else {
            return nil
        }

        return UInt64(seconds * 1000000000)
    }

    init(
        type: String?,
        succeeded: Bool?,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        error: NSError? = nil
    ) {
        self.type = type
        self.succeeded = succeeded
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.error = error
    }

    init(_ event: Any?) {
        guard let object = event as AnyObject? else {
            self.init(type: nil, succeeded: nil)
            return
        }

        self.init(
            type: (Self.value(of: object, "type") as? NSNumber).map {
                Self.name(ofType: $0.intValue)
            },
            succeeded: (Self.value(of: object, "succeeded") as? NSNumber)?.boolValue,
            startedAt: Self.value(of: object, "startDate") as? Date,
            endedAt: Self.value(of: object, "endDate") as? Date,
            error: Self.value(of: object, "error") as? NSError
        )
    }

    /// `setup`, `import` and `export` are 0, 1 and 2 — read out of the framework
    /// rather than assumed, and an unrecognised value is reported as its number
    /// because a fourth type would otherwise be silently named after the third.
    static func name(ofType raw: Int) -> String {
        switch raw {
        case 0: "setup"
        case 1: "import"
        case 2: "export"
        default: "unrecognised(\(raw))"
        }
    }

    /// Guarded by `responds(to:)`, because `value(forKey:)` on a key an object
    /// does not have raises an ObjC exception Swift cannot catch — the same trap
    /// that cost `permissions` its Siri probe.
    private static func value(of object: AnyObject, _ key: String) -> Any? {
        guard object.responds(to: Selector((key))) else {
            return nil
        }

        return object.value(forKey: key)
    }
}
