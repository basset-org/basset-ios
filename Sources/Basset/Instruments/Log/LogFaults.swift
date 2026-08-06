import BassetECS
import Foundation

/// Every error and fault logged inside this process, whoever emitted it.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` reads what was written *in this
/// process*, which is far more than the app's own logging: CFNetwork,
/// `com.apple.network`, CoreData, UIKit and every other framework running inside
/// the app log here too, with no entitlement and no debugger. It is the one
/// genuinely unharvested surface on the platform, and this is the broad net over
/// it — `swiftui.runtimeIssues` is the curated version aimed at one subsystem.
///
/// **Severity rather than a subsystem list**, because the point is to catch the
/// framework nobody thought to name. A deny-list would need to know every
/// subsystem Apple might add; `.error` and `.fault` need to know nothing.
///
/// Three limits that make this corroborating rather than primary, and they are
/// the mechanism's rather than this instrument's: most interpolated values read
/// `<private>` unless the emitter marked them public, `.debug` is not persisted
/// in a release build, and retention depends on system-wide log pressure. It also
/// does not reach `mediaserverd`, `securityd` or `VTDecoderXPCService`, which is
/// where a great deal of framework logging actually lives.
///
/// **The message text leaves the device as it was written.** The store masks what
/// an emitter marked private, so what ships is what somebody chose to log
/// publicly — an app that logged an address or a token as public sends it here.
final class LogFaults: StreamingInstrument {
    static let id: InstrumentWireID = .logFaults
    static let entity = Entity.WireID.logRecord

    /// Enough to describe what is wrong without letting one storm spend the
    /// request's budget. What is left out is reported as a count.
    private static let subjectsPerFlush = 24

    private let reader: LogStoreReader = .init(subsystems: [])

    init() {}

    static func write(
        _ digest: LogDigest,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        for (index, subject) in digest.subjects.enumerated() {
            if index == 0 {
                put(subject, over: window, into: &out)
                continue
            }
            out.also(entity) { sibling in put(subject, over: window, into: &sibling) }
        }

        guard digest.omitted > 0 else {
            return
        }

        out.also(entity) { sibling in
            sibling.put(.windowNanoseconds(window.nanoseconds))
            sibling.put(.mechanismStatus("truncated: \(digest.omitted) more"))
        }
    }

    private static func put(
        _ subject: LogDigest.Subject,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        // The window rides every row, not only the first. A count with nothing to
        // divide it by is the defect `swiftui.runtimeIssues` already found on its
        // sibling rows.
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.logSubsystem(subject.subsystem))
        out.put(.logCategory(subject.category))
        out.put(.logMessage(subject.message))
        out.put(.logLevel(subject.level.rawValue))
        out.put(.occurrenceCount(subject.count))
    }

    func observe(_ context: Context) {
        // Fifteen seconds because that is what the mechanism costs, not what
        // would be nice. `swiftui.runtimeIssues` measured a drain at roughly ten
        // seconds of wall clock on device however little there is to read, and a
        // timer that cannot keep its interval publishes a rate nobody can reason
        // about. Records are still counted over the whole interval, so asking
        // less often loses nothing but latency.
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records):
                let digest = LogDigest(
                    records,
                    ceiling: Self.subjectsPerFlush,
                    admitting: { $0.level.isDiagnostic }
                )
                guard !digest.isEmpty else {
                    return
                }

                Self.write(digest, over: window, into: &out)
            }
        }
    }

    func stopObserving() {}
}
