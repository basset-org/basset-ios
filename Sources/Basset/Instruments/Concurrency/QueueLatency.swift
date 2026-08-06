import BassetECS
import Foundation

/// How long a block waits before the main queue gets to it.
///
/// A different question from `concurrency.mainThreadHang`, and the pair is worth
/// ordering together. A hang is the main thread not reaching idle for seconds —
/// a freeze somebody notices. Latency is the queue running, but late: forty
/// milliseconds of wait, over and over, which no watchdog reports and which is
/// exactly what a dropped frame is made of.
///
/// The probe is a block timestamped when it is submitted and again when it runs,
/// so what is measured is the wait rather than the work. It is submitted once per
/// window and never re-submitted while one is outstanding, so a main queue that
/// has stopped answering accumulates one probe rather than a backlog that becomes
/// its own problem.
final class QueueLatency: StreamingInstrument, @unchecked Sendable {
    static let id: InstrumentWireID = .queueLatency
    static let entity = Entity.WireID.dispatchQueue

    private let clock: Clock = .init()
    private let lock: NSLock = .init()
    private var outstandingSince: MonotonicTime?
    private var samples: [UInt64] = []

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self else {
                return
            }

            self.report(over: window, into: &out)
            self.probe()
        }
    }

    func stopObserving() {
        lock.withLock {
            outstandingSince = nil
            samples.removeAll()
        }
    }

    private func probe() {
        let submitted = clock.now()
        let alreadyWaiting = lock.withLock { () -> Bool in
            guard outstandingSince == nil else {
                return true
            }

            outstandingSince = submitted
            return false
        }
        guard !alreadyWaiting else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let waited = self.clock.now().nanoseconds &- submitted.nanoseconds
            self.lock.withLock {
                self.outstandingSince = nil
                self.samples.append(waited)
            }
        }
    }

    private func report(over window: Context.FlushWindow, into out: inout Readings) {
        let (taken, waitingSince) = lock.withLock { () -> ([UInt64], MonotonicTime?) in
            defer { samples.removeAll() }
            return (samples, outstandingSince)
        }

        guard let worst = taken.max() else {
            // Nothing came back. Either no probe has completed yet, or the main
            // queue has not run one since it was submitted — and the second is a
            // finding rather than an absence, so the wait so far is reported as
            // the latency it already is.
            guard let waitingSince else {
                return
            }

            out.put(.queueLabel("main"))
            out
                .put(.queueLatencyNanoseconds(clock.now().nanoseconds &- waitingSince
                        .nanoseconds))
            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.mechanismStatus("still waiting"))
            return
        }

        out.put(.queueLabel("main"))
        out.put(.queueLatencyNanoseconds(worst))
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.occurrenceCount(UInt64(taken.count)))
    }
}
