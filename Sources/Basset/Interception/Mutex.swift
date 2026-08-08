import os

/// State that cannot be reached without holding the lock, because the lock owns
/// it. A lock beside the thing it guards is a convention, and a reader that
/// forgets it compiles: `HookSite` guarded its writers and left fifteen thunks
/// reading the array unguarded, which retained a freed buffer.
///
/// The standard library's `Mutex` is this, and is iOS 18. Everything below the
/// initialiser is what closes that gap; when the floor reaches iOS 18, deleting
/// this file and importing `Synchronization` leaves every call site as it is.
struct Mutex<Value>: @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<Value>

    init(_ initialValue: Value) {
        storage = OSAllocatedUnfairLock(uncheckedState: initialValue)
    }

    /// Never call out to anything that can take another lock, run app code, or
    /// come back here: `os_unfair_lock` is not recursive and traps rather than
    /// blocking when it catches itself.
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try storage.withLockUnchecked { try body(&$0) }
    }
}
