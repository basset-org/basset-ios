import Foundation

/// A shared runner has no idle capacity, so timing-sensitive tests report its load.
enum TestMachine {
    /// A safety net, not a measurement — hitting it means a thread is genuinely stuck.
    static let joinTimeout: TimeInterval = 60

    /// Simulator-only — the host already passes these tests under ThreadSanitizer.
    static var isSharedSimulator: Bool {
        ProcessInfo.processInfo.environment["BASSET_SHARED_SIMULATOR"] == "true"
    }
}
