import os

/// Polyfills Synchronization.Mutex below iOS 18 — delete this file when the floor rises.
struct Mutex<Value>: ~Copyable, @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<Value>

    init(_ initialValue: Value) {
        storage = OSAllocatedUnfairLock(uncheckedState: initialValue)
    }

    /// Never call anything that can re-lock — os_unfair_lock traps rather than blocking.
    borrowing func withLock<Result>(
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result {
        try storage.withLockUnchecked { try body(&$0) }
    }
}
