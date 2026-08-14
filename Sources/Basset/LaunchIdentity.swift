import Foundation

/// Which run of the app a reading came from. Random, not counted: a counter needs to persist.
public enum LaunchIdentity {
    public static let current: UInt64 = .random(in: 1...UInt64.max)
}
