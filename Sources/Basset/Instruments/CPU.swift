import BassetEntityComponent
import Foundation

final class ThreadCPUUsage: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let windowSeconds: Int
    }

    struct Baseline {
        var totals: [UInt64: UInt64] = [:]
        var sawEveryThread = false
    }

    struct Consumed {
        let sample: ThreadSample
        let nanoseconds: UInt64
    }

    static let id: InstrumentID = .cpuThreadUsage
    static let defaultConfig: Config = .init(windowSeconds: 5)

    private static let ceiling = 32
    /// Below the minimum a read spends the budget too fast; above it a spike ages out.
    private static let minimumWindowSeconds = 1
    private static let maximumWindowSeconds = 30

    let windowSeconds: Int

    private let previous: Mutex<Baseline> = .init(Baseline())

    init(config: Config) {
        windowSeconds = min(
            max(config.windowSeconds, Self.minimumWindowSeconds),
            Self.maximumWindowSeconds
        )
    }

    func observe(_ context: Context) {
        context.flush(every: .seconds(windowSeconds), into: .thread) { [weak self] out, window in
            guard let self else {
                return
            }

            self.write(ThreadInventory.snapshot(), over: window, into: &out)
        }
    }

    func stopObserving() {
        previous.withLock { $0 = Baseline() }
    }

    func consumed(in taken: ThreadInventory.Snapshot,
                  within windowNanoseconds: UInt64) -> [Consumed]
    {
        previous.withLock { previous in
            // A thread absent from the last window was created since it, so all of its
            // time was spent inside this one. Skipping it instead would hide any thread
            // that does not outlive two windows, however much of a core it burned.
            // Only a window that saw every thread can say a thread was absent from it;
            // one the kernel refused a thread in would report a lifetime as a window.
            let absenceMeansNew = !previous.totals.isEmpty && previous.sawEveryThread
            var current = [UInt64: UInt64]()
            var consumed = [Consumed]()
            for sample in taken.samples where sample.identifier != 0 {
                let total = sample.cpuNanoseconds
                current[sample.identifier] = total
                guard let before = previous.totals[sample.identifier] else {
                    if absenceMeansNew, total > 0 {
                        consumed.append(Consumed(
                            sample: sample,
                            // One thread cannot burn more than the window it ran in.
                            nanoseconds: min(total, windowNanoseconds)
                        ))
                    }
                    continue
                }
                guard total > before else {
                    continue
                }

                consumed.append(Consumed(sample: sample, nanoseconds: total - before))
            }

            previous = Baseline(totals: current, sawEveryThread: taken.isComplete)
            return consumed
        }
    }

    private func write(
        _ taken: ThreadInventory.Snapshot,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        let busy = consumed(in: taken, within: window.nanoseconds)
            .sorted { $0.nanoseconds > $1.nanoseconds }

        guard let first = busy.first else {
            return
        }

        put(first, over: window, into: &out)
        for entry in busy.dropFirst(1).prefix(Self.ceiling - 1) {
            out.also(out.entity) { additional in put(entry, over: window, into: &additional) }
        }

        guard busy.count > Self.ceiling else {
            return
        }

        out.also(out.entity) { additional in
            additional.put(.windowNanoseconds(window.nanoseconds))
            additional.put(.mechanismStatus("truncated: \(busy.count - Self.ceiling) more"))
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

    private let previous: Mutex<ProcessWakeups?> = .init(nil)

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(1), into: .process) { [weak self] out, window in
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
