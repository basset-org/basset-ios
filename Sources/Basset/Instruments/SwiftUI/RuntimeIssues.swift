import BassetECS
import Foundation

/// SwiftUI reports its own undefined behaviour, in release, on every device, and
/// nobody reads it. `StoredLocationBase.set(_:transaction:)` and its neighbours
/// log a **fault** to `com.apple.runtime-issues`; Xcode's purple banner is a
/// presentation of a record that exists whether or not a debugger is attached.
///
/// What arrives is the rule that was broken and when. There is no backtrace in
/// an `OSLogEntryLog`, so this instrument answers "the app modified state during
/// a view update at 14:22:11" and never "in `CartView`". Pair it with
/// `swiftui.host.appear` to bound which screen was on.
final class RuntimeIssues: StreamingInstrument {
    static let id: InstrumentWireID = .swiftUIRuntimeIssues
    static let entity = Entity.WireID.swiftUIRuntimeIssue

    /// `runtime-issues` carries SwiftUI's own violations. `attributegraph`
    /// carries the non-fatal precondition failures, which are the survivable half
    /// of the family that otherwise aborts. `SwiftUI` carries `_logChanges()`
    /// output, which only exists if the app asked for it — free when present,
    /// absent otherwise, and filtered by category so ordinary framework chatter
    /// does not crowd out a fault.
    private static let subsystems = [
        "com.apple.runtime-issues",
        "com.apple.attributegraph",
        "com.apple.SwiftUI",
    ]
    /// One flush describes a burst rather than transcribing it: a re-render storm
    /// repeats the same violation thousands of times, and thousands of identical
    /// readings would spend a request's whole budget saying one thing.
    private static let subjectsPerFlush = 16

    private let reader: LogStoreReader = .init(subsystems: RuntimeIssues.subsystems)

    init() {}

    /// The window goes on every row, not only the first. One flush becomes one
    /// entity per distinct violation, so a window on the first row alone leaves
    /// every sibling carrying a count with nothing to divide it by.
    private static func write(
        _ digest: RuntimeIssueDigest,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        for (index, subject) in digest.subjects.enumerated() {
            if index == 0 {
                put(subject, over: window, into: &out)
                continue
            }
            out.also(Entity.WireID.swiftUIRuntimeIssue) { sibling in
                put(subject, over: window, into: &sibling)
            }
        }
        guard digest.omitted > 0 else {
            return
        }

        out.also(Entity.WireID.swiftUIRuntimeIssue) { sibling in
            sibling.put(.windowNanoseconds(window.nanoseconds))
            sibling.put(.mechanismStatus("truncated: \(digest.omitted) more"))
        }
    }

    private static func put(
        _ subject: RuntimeIssueDigest.Subject,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.logSubsystem(subject.subsystem))
        out.put(.logCategory(subject.category))
        out.put(.logMessage(subject.message))
        out.put(.occurrenceCount(subject.count))
    }

    func observe(_ context: Context) {
        // Fifteen seconds is what the mechanism costs, not what would be nice. On
        // device an `OSLogStore` drain takes roughly ten seconds of wall clock
        // however little there is to read, so a two-second timer never idles — it
        // runs back to back and still delivers every ten. An interval the
        // instrument cannot keep is a rate nobody can reason about.
        //
        // Violations are counted over the whole interval, so asking less often
        // loses nothing but latency.
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records):
                let digest = RuntimeIssueDigest(records, ceiling: Self.subjectsPerFlush)
                guard !digest.isEmpty else {
                    return
                }

                Self.write(digest, over: window, into: &out)
            }
        }
    }

    func stopObserving() {}
}
