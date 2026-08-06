import BassetECS
import Foundation

final class Wakeups: StreamingInstrument {
    static let id: InstrumentWireID = .cpuWakeups
    static let entity = Entity.WireID.process

    private let lock: NSLock = .init()
    private var previous: ProcessWakeups?

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self else {
                return
            }

            self.write(ProcessWakeups.read(), over: window, into: &out)
        }
    }

    func stopObserving() {
        lock.withLock { previous = nil }
    }

    private func write(
        _ now: ProcessWakeups?,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        guard let now else {
            out.put(.mechanismStatus("unavailable: the task reported no power info"))
            return
        }

        let before = lock.withLock { () -> ProcessWakeups? in
            defer { previous = now }
            return previous
        }
        guard let before else {
            return
        }

        out.put(.wakeupCount(now.interrupts &- before.interrupts))
        out.put(.idleWakeupCount(now.platformIdle &- before.platformIdle))
        out.put(.windowNanoseconds(window.nanoseconds))
    }
}
