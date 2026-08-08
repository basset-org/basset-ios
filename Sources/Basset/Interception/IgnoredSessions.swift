import Foundation

public enum IgnoredSessions {
    private static let owned: Mutex<Set<ObjectIdentifier>> = .init([])

    public static func remember(_ session: AnyObject) {
        owned.withLock { $0.insert(ObjectIdentifier(session)) }
    }

    public static func contains(_ session: AnyObject) -> Bool {
        owned.withLock { $0.contains(ObjectIdentifier(session)) }
    }

    public static func forget(_ session: AnyObject) {
        owned.withLock { $0.remove(ObjectIdentifier(session)) }
    }
}
