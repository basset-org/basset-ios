@testable import Basset
import BassetEntityComponent
import Foundation

/// Activates an instrument for real so a test asserts the wiring, not what a `write` test checks.
final class InstrumentHarness<Instrument: Streamable & PlainInstrument>: @unchecked Sendable {
    let instrument: Instrument
    /// Reachable so a test can seed what the load-time half would have caught.
    let registries: Registries = .init()

    private let status: AtomicStatus = .init()
    private let lock: NSLock = .init()
    private var collected: [Entity] = []
    private var context: Context?

    /// Everything the instrument has emitted so far, oldest first.
    var readings: [Entity] {
        lock.withLock { collected }
    }

    init(_ build: () -> Instrument = { Instrument() }) {
        instrument = build()
    }

    func start() {
        status.activate()
        let context = Context(
            status: status,
            swizzle: Swizzle(),
            registries: registries,
            timerQueue: DispatchQueue(label: "basset.test.\(Instrument.name)"),
            tallySlots: Instrument.tallySlots,
            sink: { [weak self] entity in
                self?.lock.withLock { self?.collected.append(entity) }
            }
        )
        self.context = context
        instrument.observe(context)
    }

    func stop() {
        instrument.stopObserving()
        context?.teardown()
        status.deactivate()
        context = nil
    }

    func forget() {
        lock.withLock { collected.removeAll() }
    }

    /// Waits rather than sleeping fixed — delivery often lands on a different queue.
    @discardableResult
    func waitForReading(timeout: TimeInterval = 2) -> Entity? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = readings.first {
                return first
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return readings.first
    }

    func value(_ id: Component.ID, in entity: Entity?) -> String? {
        entity?.components.first { $0.known == id }?.value.rendered
    }
}
