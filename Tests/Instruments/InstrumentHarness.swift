@testable import Basset
import BassetECS
import Foundation

/// Runs an instrument the way the runtime does, so a test can assert the
/// *wiring* rather than the arithmetic.
///
/// Every other test in this suite calls an instrument's `write` function with a
/// value built by hand. Those are worth having and they check the wrong half:
/// they pass unchanged if the notification name is wrong, if `observe` never
/// registers an observer, if the emit path is broken, or if `observe` is empty.
/// Both real defects of that shape — a Core Data notification whose value is not
/// its symbol's name, and a `UIAccessibility` constant that does not exist — are
/// invisible to a `write` test.
///
/// So this activates the instrument, hands it a real `Context`, lets the test
/// provoke whatever the mechanism listens for, and collects what came out. On the
/// simulator rung that means the mechanism runs against the real frameworks,
/// which is as close to a device as a test gets.
final class InstrumentHarness<Instrument: StreamingInstrument>: @unchecked Sendable {
    let instrument: Instrument

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
            instrumentName: Instrument.name,
            defaultEntity: Instrument.entity,
            status: status,
            swizzle: Swizzle(),
            registries: Registries(),
            timerQueue: DispatchQueue(label: "basset.test.\(Instrument.name)"),
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

    /// Waits for a reading rather than sleeping a fixed amount. Several of these
    /// mechanisms deliver on a queue that is not the caller's, so a bare
    /// assertion after posting is a race that passes on a fast machine.
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

    func value(_ id: Component.WireID, in entity: Entity?) -> String? {
        entity?.components.first { $0.id == id }?.value.rendered
    }
}
