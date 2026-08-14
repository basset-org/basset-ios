import CBassetAtomics

/// Below iOS 18's Synchronization.Atomic; audio forbids locks on the render thread.
public enum Atomics {
    @inline(__always)
    public static func initialize(_ slot: UnsafeMutablePointer<UInt8>, _ value: UInt8) {
        slot.initialize(to: value)
    }

    @inline(__always)
    public static func loadRelaxed(_ slot: UnsafeMutablePointer<UInt8>) -> UInt8 {
        basset_atomic_load_relaxed_u8(slot)
    }

    @inline(__always)
    public static func storeReleasing(
        _ slot: UnsafeMutablePointer<UInt8>,
        _ value: UInt8
    ) {
        basset_atomic_store_release_u8(slot, value)
    }

    @inline(__always)
    public static func initialize(_ slot: UnsafeMutablePointer<UInt64>, _ value: UInt64) {
        slot.initialize(to: value)
    }

    @inline(__always)
    public static func loadRelaxed(_ slot: UnsafeMutablePointer<UInt64>) -> UInt64 {
        basset_atomic_load_relaxed_u64(slot)
    }

    @inline(__always)
    public static func storeRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) {
        basset_atomic_store_relaxed_u64(slot, value)
    }

    @inline(__always)
    public static func addRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) -> UInt64 {
        basset_atomic_add_relaxed_u64(slot, value)
    }

    @inline(__always)
    public static func exchangeRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ value: UInt64
    ) -> UInt64 {
        basset_atomic_exchange_relaxed_u64(slot, value)
    }

    @inline(__always)
    public static func compareExchangeWeakRelaxed(
        _ slot: UnsafeMutablePointer<UInt64>,
        _ expected: inout UInt64,
        _ desired: UInt64
    ) -> Bool {
        withUnsafeMutablePointer(to: &expected) {
            basset_atomic_compare_exchange_weak_relaxed_u64(slot, $0, desired)
        }
    }
}
