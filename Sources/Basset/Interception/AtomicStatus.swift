public enum InstrumentStatus: UInt8, Sendable {
    case inactive = 0
    case active = 1
}

/// The hot path reads this on every hooked call, so it is lock-free rather than
/// cheap-lock. See Atomics for why that is reachable at the iOS 17 floor.
public final class AtomicStatus: @unchecked Sendable {
    private let cell: UnsafeMutablePointer<UInt8>

    public var isActive: Bool {
        Atomics.loadRelaxed(cell) == InstrumentStatus.active.rawValue
    }

    public var current: InstrumentStatus {
        InstrumentStatus(rawValue: Atomics.loadRelaxed(cell)) ?? .inactive
    }

    public init() {
        cell = .allocate(capacity: 1)
        Atomics.initialize(cell, InstrumentStatus.inactive.rawValue)
    }

    deinit {
        cell.deallocate()
    }

    public func activate() {
        Atomics.storeReleasing(cell, InstrumentStatus.active.rawValue)
    }

    public func deactivate() {
        Atomics.storeReleasing(cell, InstrumentStatus.inactive.rawValue)
    }
}
