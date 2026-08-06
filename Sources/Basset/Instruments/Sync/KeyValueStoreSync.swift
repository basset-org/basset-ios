import BassetECS
import Foundation

/// Why `NSUbiquitousKeyValueStore` stopped syncing, which it otherwise does
/// silently.
///
/// The store holds 1 MB across at most 1024 keys. Past either ceiling it does not
/// throw, does not return false and does not log — it simply stops
/// synchronising, and the app goes on writing to a store that no longer leaves
/// the device. `QuotaViolationChange` is the only announcement, and an app that
/// is not listening for it never learns.
///
/// The account reason matters nearly as much: a user signing out of iCloud wipes
/// the store's contents from the app's point of view, and an app that reads a
/// setting back as nil concludes the user never set it.
final class KeyValueStoreSync: StreamingInstrument {
    static let id: InstrumentWireID = .keyValueStoreSync
    static let entity = Entity.WireID.keyValueStore

    static let notification =
        Notification.Name("NSUbiquitousKeyValueStoreDidChangeExternallyNotification")
    static let reasonKey = "NSUbiquitousKeyValueStoreChangeReasonKey"
    static let changedKeysKey = "NSUbiquitousKeyValueStoreChangedKeysKey"

    private var observer: NSObjectProtocol?

    init() {}

    static func write(_ userInfo: [AnyHashable: Any]?, into out: inout Readings) {
        guard let raw = (userInfo?[reasonKey] as? NSNumber)?.intValue else {
            out.put(.changeReason("unstated"))
            out.put(.mechanismStatus("the store changed without saying why"))
            return
        }

        out.put(.changeReason(name(ofReason: raw)))
        if let keys = userInfo?[changedKeysKey] as? [String] {
            // The count, never the keys. A key name is the app's own vocabulary
            // and routinely carries a user's identifiers in it.
            out.put(.changedKeyCount(UInt32(clamping: keys.count)))
        }
    }

    /// Server 0, initial sync 1, quota violation 2, account change 3 — read out
    /// of the framework rather than assumed. An unrecognised value keeps its
    /// number rather than being named after the nearest one that is known.
    static func name(ofReason raw: Int) -> String {
        switch raw {
        case 0: "serverChange"
        case 1: "initialSync"
        case 2: "quotaViolation"
        case 3: "accountChange"
        default: "unrecognised(\(raw))"
        }
    }

    func observe(_ context: Context) {
        observer = NotificationCenter.default.addObserver(
            forName: Self.notification,
            object: nil,
            queue: nil
        ) { note in
            context.emit { out in
                Self.write(note.userInfo, into: &out)
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
