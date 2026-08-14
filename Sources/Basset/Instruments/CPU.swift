import BassetECS
import Foundation

final class ThreadCPUUsage: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let windowSeconds: Int
    }

    private struct Consumed {
        let sample: ThreadSample
        let nanoseconds: UInt64
    }

    static let id: InstrumentID = .cpuThreadUsage
    static let entity = Entity.ID.thread
    static let defaultConfig: Config = .init(windowSeconds: 1)

    private static let ceiling = 32
    /// Below the minimum a read spends the budget too fast; above it a spike ages out.
    private static let minimumWindowSeconds = 1
    private static let maximumWindowSeconds = 30

    let windowSeconds: Int

    private let previous: Mutex<[UInt64: UInt64]> = .init([:])

    init(config: Config) {
        windowSeconds = min(
            max(config.windowSeconds, Self.minimumWindowSeconds),
            Self.maximumWindowSeconds
        )
    }

    func observe(_ context: Context) {
        context.flush(every: .seconds(windowSeconds)) { [weak self] out, window in
            guard let self else {
                return
            }

            self.write(ThreadInventory.read(), over: window, into: &out)
        }
    }

    func stopObserving() {
        previous.withLock { $0.removeAll() }
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
        previous.withLock { previous in
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

final class Wakeups: Streamable, PlainInstrument {
    static let id: InstrumentID = .cpuWakeups
    static let entity = Entity.ID.process

    private let previous: Mutex<ProcessWakeups?> = .init(nil)

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
        previous.withLock { $0 = nil }
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

        let before = previous.withLock { previous -> ProcessWakeups? in
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
