import BassetECS
import Foundation

final class ThreadCPUUsage: StreamingInstrument {
    private struct Consumed {
        let sample: ThreadSample
        let nanoseconds: UInt64
    }

    static let id: InstrumentWireID = .cpuThreadUsage
    static let entity = Entity.WireID.thread

    /// Threads that used no measurable CPU are not emitted, so a busy handful
    /// does not arrive buried in fifty idle rows. The count of what was left out
    /// still does.
    private static let ceiling = 32

    private let lock: NSLock = .init()
    private var previous: [UInt64: UInt64] = [:]

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self else {
                return
            }

            self.write(ThreadInventory.read(), over: window, into: &out)
        }
    }

    func stopObserving() {
        lock.withLock { previous.removeAll() }
    }

    private func write(
        _ samples: [ThreadSample],
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        let busy = consumed(in: samples)
            .sorted { $0.nanoseconds > $1.nanoseconds }

        guard let first = busy.first else {
            return
        }

        put(first, over: window, into: &out)
        for entry in busy.dropFirst(1).prefix(Self.ceiling - 1) {
            out.also(Self.entity) { sibling in put(entry, over: window, into: &sibling) }
        }

        guard busy.count > Self.ceiling else {
            return
        }

        out.also(Self.entity) { sibling in
            sibling.put(.windowNanoseconds(window.nanoseconds))
            sibling.put(.mechanismStatus("truncated: \(busy.count - Self.ceiling) more"))
        }
    }

    private func consumed(in samples: [ThreadSample]) -> [Consumed] {
        lock.lock()
        defer { lock.unlock() }

        var current = [UInt64: UInt64]()
        var consumed = [Consumed]()
        for sample in samples where sample.identifier != 0 {
            let total = sample.cpuNanoseconds
            current[sample.identifier] = total
            guard let before = previous[sample.identifier],
                  total > before
            else {
                continue
            }

            consumed.append(Consumed(sample: sample, nanoseconds: total - before))
        }
        previous = current
        return consumed
    }

    private func put(
        _ entry: Consumed,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.threadIdentifier(entry.sample.identifier))
        out.put(.cpuNanoseconds(entry.nanoseconds))
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.threadIsMain(entry.sample.isMain))
        out.put(.threadRunState(entry.sample.runState))
        out.put(.cpuUsageRatio(entry.sample.cpuUsageRatio))
        if !entry.sample.name.isEmpty {
            out.put(.threadName(entry.sample.name))
        }
    }
}
