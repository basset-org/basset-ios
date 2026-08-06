
public struct TallySlot: Equatable, Sendable {
    public static let first: TallySlot = .init(0)
    public static let second: TallySlot = .init(1)
    public static let third: TallySlot = .init(2)
    public static let fourth: TallySlot = .init(3)

    let index: Int

    public init(_ index: Int) {
        precondition(index >= 0, "a tally slot is never negative")
        self.index = index
    }
}

/// Counters an instrument accumulates on a hot path and the runner drains on an
/// interval. Preallocated and lock-free, because the catalog's hottest surfaces —
/// a 60 fps sample-buffer delegate, a 100 Hz CoreMotion handler, layoutSubviews —
/// may not allocate or lock, and because a naive per-reading emit burns a
/// 500-reading cap in eight seconds.
public final class Tally: @unchecked Sendable {
    public let capacity: Int

    private let slots: UnsafeMutablePointer<UInt64>

    public init(slots capacity: Int = 4) {
        precondition(capacity > 0, "a tally needs at least one slot")
        self.capacity = capacity
        slots = .allocate(capacity: capacity)
        for index in 0 ..< capacity {
            Atomics.initialize(slots + index, 0)
        }
    }

    deinit {
        slots.deallocate()
    }

    public func add(_ slot: TallySlot, _ count: UInt64 = 1) {
        _ = Atomics.addRelaxed(cell(slot), count)
    }

    public func raise(_ slot: TallySlot, to candidate: UInt64) {
        let cell = self.cell(slot)
        var current = Atomics.loadRelaxed(cell)
        while candidate > current {
            if Atomics.compareExchangeWeakRelaxed(cell, &current, candidate) {
                return
            }
        }
    }

    public func take(_ slot: TallySlot) -> UInt64 {
        Atomics.exchangeRelaxed(cell(slot), 0)
    }

    public func read(_ slot: TallySlot) -> UInt64 {
        Atomics.loadRelaxed(cell(slot))
    }

    private func cell(_ slot: TallySlot) -> UnsafeMutablePointer<UInt64> {
        precondition(
            slot.index < capacity,
            "tally slot \(slot.index) is outside the \(capacity) this instrument declared"
        )
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

    public func now() -> MonotonicTime {
        clock.now()
    }
}
