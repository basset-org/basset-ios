import Foundation

public enum IgnoredSessions {
    private struct Holder {
        weak var session: AnyObject?
    }

    /// Held weakly: a freed session's address can be reissued to one the app made.
    private static let owned: Mutex<[ObjectIdentifier: Holder]> = .init([:])

    public static func add(_ session: AnyObject) {
        owned.withLock { held in
            held = held.filter { $0.value.session != nil }
            held[ObjectIdentifier(session)] = Holder(session: session)
        }
    }

    public static func contains(_ session: AnyObject) -> Bool {
        owned.withLock { $0[ObjectIdentifier(session)]?.session === session }
    }

    public static func remove(_ session: AnyObject) {
        owned.withLock { $0.removeValue(forKey: ObjectIdentifier(session)) }
    }
}
