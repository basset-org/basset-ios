import Foundation

/// A reading's own identity within this process, for `entityParent` to point back at. One
/// counter shared by every instrument — never reset while the process runs — so two entities
/// can never collide regardless of which instrument produced them or how many times it fired.
/// Paired with `launchId`, which rides every reading automatically, for uniqueness across a
/// crash or relaunch: `entityId` alone only ever needs to be unique within one launch.
enum EntityIdentity {
    private static let counter: Mutex<UInt32> = .init(0)

    static func next() -> UInt32 {
        counter.withLock { count in
            count &+= 1
            return count
        }
    }
}
