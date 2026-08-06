import Builtin

/// Lock-free primitives at the SDK's iOS 17 floor. Synchronization.Atomic is
/// iOS 18, and a lock is not an option: audio's release gate forbids locking on a
/// render thread, and the status flag is read on every hooked call.
///
/// These are the same builtins Synchronization.Atomic is written over — its
/// members are @_alwaysEmitIntoClient, so Apple already inlines this exact
/// instruction sequence into every iOS 18 client binary. Codegen here is
/// identical to a C stdatomic shim, which is what this replaces.
///
/// The cost is an experimental flag and unstable surface. It fails loudly rather
/// than silently: a toolchain that drops it gives "no such module 'Builtin'" at
/// compile time, never a miscompile. When the floor reaches iOS 18 this becomes a
/// wrapper over Synchronization.Atomic and nothing else changes.
public enum Atomics {
    @_transparent
    public static func initialize(_ slot: UnsafeMutablePointer<UInt8>, _ value: UInt8) {
        slot.initialize(to: value)
    }

    @_transparent
    public static func loadRelaxed(_ slot: UnsafeMutablePointer<UInt8>) -> UInt8 {
        Builtin.reinterpretCast(Builtin.atomicload_monotonic_Int8(slot._rawValue))
    }

    @_transparent
    public static func storeReleasing(
        _ slot: UnsafeMutablePointer<UInt8>,
        _ value: UInt8
    ) {
        Builtin.atomicstore_release_Int8(slot._rawValue, Builtin.reinterpretCast(value))
    }

    @_transparent
    public static func initialize(_ slot: UnsafeMutablePointer<UInt64>, _ value: UInt64) {
        slot.initialize(to: value)
    }

    @_transparent
    public static func loadRelaxed(_ slot: UnsafeMutablePointer<UInt64>) -> UInt64 {
        Builtin.reinterpretCast(Builtin.atomicload_monotonic_Int64(slot._rawValue))
    }

    @_transparent
    public static func storeRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) {
        Builtin.atomicstore_monotonic_Int64(
            slot._rawValue,
            Builtin.reinterpretCast(value)
        )
    }

    @_transparent
    public static func addRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) -> UInt64 {
        Builtin.reinterpretCast(
            Builtin.atomicrmw_add_monotonic_Int64(
                slot._rawValue,
                Builtin.reinterpretCast(value)
            )
        )
    }

    @_transparent
    public static func exchangeRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) -> UInt64 {
        Builtin.reinterpretCast(
            Builtin.atomicrmw_xchg_monotonic_Int64(
                slot._rawValue,
                Builtin.reinterpretCast(value)
            )
        )
    }

    @_transparent
    public static func compareExchangeWeakRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ expected: inout UInt64,
        _ desired: UInt64
    ) -> Bool {
        let (original, exchanged) = Builtin.cmpxchg_monotonic_monotonic_weak_Int64(
            slot._rawValue,
            Builtin.reinterpretCast(expected) as Builtin.Int64,
            Builtin.reinterpretCast(desired) as Builtin.Int64
        )
        expected = Builtin.reinterpretCast(original)
        return Bool(exchanged)
    }
}
