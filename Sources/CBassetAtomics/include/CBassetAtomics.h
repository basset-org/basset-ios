#ifndef CBASSET_ATOMICS_H
#define CBASSET_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

// Lock-free atomics at the iOS 17 floor, below Synchronization.Atomic. The __atomic
// builtins are defined to operate on ordinary caller-owned storage — the same contract
// Swift's own atomic builtins relied on — so the Swift side keeps its plain UInt8/UInt64
// cells and no _Atomic object is required. Eight-byte-aligned integers are lock-free on
// the 64-bit Apple targets this ships to: a read-modify-write may spin on a load/store
// pair on a CPU without LSE, but none of these takes a lock, so they are safe on the
// audio render thread, which forbids them.

static inline uint8_t basset_atomic_load_relaxed_u8(uint8_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_RELAXED);
}

static inline void basset_atomic_store_release_u8(uint8_t *slot, uint8_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELEASE);
}

static inline uint64_t basset_atomic_load_relaxed_u64(uint64_t *slot) {
    return __atomic_load_n(slot, __ATOMIC_RELAXED);
}

static inline void basset_atomic_store_relaxed_u64(uint64_t *slot, uint64_t value) {
    __atomic_store_n(slot, value, __ATOMIC_RELAXED);
}

static inline uint64_t basset_atomic_add_relaxed_u64(uint64_t *slot, uint64_t value) {
    return __atomic_fetch_add(slot, value, __ATOMIC_RELAXED);
}

static inline uint64_t basset_atomic_exchange_relaxed_u64(uint64_t *slot, uint64_t value) {
    return __atomic_exchange_n(slot, value, __ATOMIC_RELAXED);
}

static inline bool basset_atomic_compare_exchange_weak_relaxed_u64(uint64_t *slot,
                                                                   uint64_t *expected,
                                                                   uint64_t desired) {
    return __atomic_compare_exchange_n(slot, expected, desired, true,
                                       __ATOMIC_RELAXED, __ATOMIC_RELAXED);
}

#endif
