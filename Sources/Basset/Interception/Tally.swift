
public struct TallySlot: Equatable, Sendable {
    public static let first: TallySlot = .init(0)
    public static let second: TallySlot = .init(1)
    public static let third: TallySlot = .init(2)
    public static let fourth: TallySlot = .init(3)

    let index: Int

    public init(_ index: Int) {
        self.index = index
    }
}

/// Hot-path counters, drained on an interval — preallocated and lock-free.
public final class Tally: @unchecked Sendable {
    public let capacity: Int

    private let slots: UnsafeMutablePointer<UInt64>

    public init(slots capacity: Int = 4) {
        // Refused, not trapped: a zero-slot tally ignores every write instead of raising.
        self.capacity = max(0, capacity)
        let allocated = max(1, self.capacity)
        slots = .allocate(capacity: allocated)
        for index in 0 ..< allocated {
            Atomics.initialize(slots + index, 0)
        }
    }

    deinit {
        slots.deallocate()
    }

    public func add(_ slot: TallySlot, _ count: UInt64 = 1) {
        guard let cell = cell(slot) else {
            return
        }

        _ = Atomics.addRelaxed(cell, count)
    }

    public func raise(_ slot: TallySlot, to candidate: UInt64) {
        guard let cell = cell(slot) else {
            return
        }

        var current = Atomics.loadRelaxed(cell)
        while candidate > current {
            if Atomics.compareExchangeWeakRelaxed(cell, &current, candidate) {
                return
            }
        }
    }

    /// Replaces and returns the previous value atomically, so a rate never loses one.
    public func exchange(_ slot: TallySlot, for value: UInt64) -> UInt64 {
        guard let cell = cell(slot) else {
            return 0
        }

        return Atomics.exchangeRelaxed(cell, value)
    }

    public func take(_ slot: TallySlot) -> UInt64 {
        guard let cell = cell(slot) else {
            return 0
        }

        return Atomics.exchangeRelaxed(cell, 0)
    }

    public func read(_ slot: TallySlot) -> UInt64 {
        guard let cell = cell(slot) else {
            return 0
        }

        return Atomics.loadRelaxed(cell)
    }

    /// Refused, not trapped — losing a count beats ending somebody else's process.
    private func cell(_ slot: TallySlot) -> UnsafeMutablePointer<UInt64>? {
        guard slot.index >= 0, slot.index < capacity else {
            return nil
        }

        return slots + slot.index
    }
}

public struct HotPath: Sendable {
    private let tally: Tally
    private let clock: Clock
    private let status: AtomicStatus

    public var isActive: Bool {
        status.isActive
    }

    init(tally: Tally, clock: Clock, status: AtomicStatus) {
        self.tally = tally
        self.clock = clock
        self.status = status
    }

    public func add(_ slot: TallySlot, _ count: UInt64 = 1) {
        tally.add(slot, count)
    }

    public func raise(_ slot: TallySlot, to candidate: UInt64) {
        tally.raise(slot, to: candidate)
    }

    public func exchange(_ slot: TallySlot, for value: UInt64) -> UInt64 {
        tally.exchange(slot, for: value)
    }

    public func now() -> MonotonicTime {
        clock.now()
    }
}
