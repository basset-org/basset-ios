import BassetECS
import Foundation

/// What threads exist, what they are called, and what the scheduler is doing
/// with them — asked without stopping any of them.
///
/// The cheap half of the pair. `runtime.threadSnapshot` answers what each thread
/// is *executing*, and pays for it by suspending the whole process, so it only
/// runs when something has already gone wrong. This answers what each thread
/// *is*, from what the kernel already knows, and can be asked at any moment.
///
/// The finding it exists for is usually a count: a thread per request, a pool
/// that grew and never shrank, forty threads named after one library. Named
/// threads make that legible in a way a stack trace does not — the name is the
/// team that created them.
final class ThreadInventoryReading: SnapshotInstrument {
    static let id: InstrumentWireID = .threadInventory
    static let entity = Entity.WireID.thread

    /// A process with more threads than this has a finding of its own, and it is
    /// the count rather than the list. Emitting hundreds of rows would spend a
    /// request's whole budget describing the symptom.
    private static let ceiling = 96

    init() {}

    static func write(_ samples: [ThreadSample], into out: inout Readings) {
        guard let first = samples.first else {
            out.put(.mechanismStatus("unavailable: the task listed no threads"))
            return
        }

        // The count goes on the first row rather than in a row of its own, so a
        // reader that takes one entity still learns how many there were.
        put(first, of: samples.count, into: &out)
        for sample in samples.dropFirst(1).prefix(ceiling - 1) {
            out.also(Self.entity) { sibling in put(
                sample,
                of: samples.count,
                into: &sibling
            ) }
        }

        guard samples.count > ceiling else {
            return
        }

        out.also(Self.entity) { sibling in
            sibling.put(.occurrenceCount(UInt64(samples.count)))
            sibling.put(.mechanismStatus("truncated: \(samples.count - ceiling) more"))
        }
    }

    private static func put(
        _ sample: ThreadSample,
        of total: Int,
        into out: inout Readings
    ) {
        out.put(.threadIndex(UInt32(sample.index)))
        out.put(.threadIdentifier(sample.identifier))
        out.put(.threadRunState(sample.runState))
        out.put(.threadIsMain(sample.isMain))
        out.put(.occurrenceCount(UInt64(total)))

        if !sample.name.isEmpty {
            out.put(.threadName(sample.name))
        }
        if sample.isIdle {
            out.put(.threadIdle(true))
        }
        out.put(.cpuUsageRatio(sample.cpuUsageRatio))
        out.put(.cpuNanoseconds(sample.cpuNanoseconds))
        out.put(.threadPriority(sample.currentPriority))
        // Only where it differs from the priority the thread asked for. Repeating
        // an unchanged base on every row would bury the one case worth seeing.
        if sample.isPriorityBoosted {
            out.put(.threadBasePriority(sample.basePriority))
        }
    }

    func reading(_ out: inout Readings) {
        Self.write(ThreadInventory.read(), into: &out)
    }
}
