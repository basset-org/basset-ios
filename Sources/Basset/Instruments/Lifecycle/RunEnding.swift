import Foundation

/// How a run ended, read out of what it managed to write down before it stopped.
///
/// Every verdict here is an inference, and the reading says so by carrying the
/// evidence beside it — the footprint, the headroom, how long the main thread had
/// been unresponsive — rather than only the conclusion. A reader that disagrees
/// with the rule can see what the rule was applied to.
///
/// What this cannot do is name a signal. `EXC_BAD_ACCESS`, an illegal instruction
/// and an uncaught exception are one verdict here, `unexpected`: separating them
/// needs a crash handler, which is the most hazardous mechanism in the catalog.
/// Every app already ships a crash reporter, and none of them answer the rest of
/// this list.
struct RunEnding: Equatable {
    /// Five seconds of a main thread that never reached idle. iOS's own watchdog
    /// fires between roughly five and twenty seconds depending on the transition,
    /// so this is under the floor rather than at the average: a run that ends
    /// while the main thread has been stuck this long ended *because* it was.
    static let watchdogThreshold: UInt64 = 5000000000

    /// Jetsam takes the process at the limit, so the last stamp before it lands
    /// shows the headroom nearly gone. Not zero: the stamp is up to a second old,
    /// and an app allocating hard covers more than nothing in that second.
    static let exhaustedHeadroomBytes: UInt64 = 16 * 1024 * 1024

    /// Pressure this old is not what killed the process, whatever else is true.
    static let pressureRelevanceMicroseconds: UInt64 = 30000000

    let reason: String
    let state: String
    let record: RunRecord

    var runDurationNanoseconds: UInt64? {
        guard record.recordedAtMicroseconds > record.startedAtMicroseconds
        else {
            return nil
        }

        return (record.recordedAtMicroseconds - record.startedAtMicroseconds) * 1000
    }

    init(_ record: RunRecord) {
        self.record = record
        state =
            switch record.appState {
            case .foreground: "foreground"
            case .background: "background"
            case .unknown: "unknown"
            }
        reason = Self.reason(for: record)
    }

    /// Ordered by how specific the evidence is, not by how common the ending is.
    /// A stuck main thread is a narrower fact than low headroom, and low headroom
    /// is narrower than the system being under pressure — so a run that shows two
    /// of them is named after the one that says most.
    private static func reason(for record: RunRecord) -> String {
        if record.cleanExit {
            return "clean"
        }
        if record.mainUnresponsiveNanoseconds >= watchdogThreshold {
            return "watchdog"
        }
        if record.memoryAvailableBytes > 0,
           record.memoryAvailableBytes < exhaustedHeadroomBytes
        {
            return "ownMemoryLimit"
        }
        if record.pressureLevel == .critical, pressureWasCurrent(in: record) {
            return "systemMemoryPressure"
        }
        // A backgrounded app that simply stops is the ordinary case: iOS reclaims
        // suspended processes constantly and tells nobody. In the foreground it is
        // the opposite — the user was looking at it, and nothing routine ends a
        // run there.
        return record.appState == .background ? "reclaimedWhileBackgrounded" : "unexpected"
    }

    private static func pressureWasCurrent(in record: RunRecord) -> Bool {
        guard record.recordedAtMicroseconds >= record.pressureRecordedAtMicroseconds
        else {
            return false
        }

        let age = record.recordedAtMicroseconds - record.pressureRecordedAtMicroseconds
        return age <= pressureRelevanceMicroseconds
    }
}
