import Foundation

public enum IgnoredSessions {
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var owned: Set<ObjectIdentifier> = []

    public static func remember(_ session: AnyObject) {
        lock.withLock { owned.insert(ObjectIdentifier(session)) }
    }

    public static func contains(_ session: AnyObject) -> Bool {
        lock.withLock { owned.contains(ObjectIdentifier(session)) }
    }

    public static func forget(_ session: AnyObject) {
        lock.withLock { owned.remove(ObjectIdentifier(session)) }
    }
}
