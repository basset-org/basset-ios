import BassetECS
import Foundation

/// A window of log records reduced to what is worth sending, separated from the
/// reading of them so the rule can be tested without a log store.
///
/// The same shape `RuntimeIssueDigest` takes for SwiftUI, generalised: group by
/// what a record *says*, count the repeats, rank by count, and report what the
/// ceiling left out rather than dropping it quietly. A framework in a bad state
/// logs the same line thousands of times, and one reading per occurrence would
/// spend a request's whole budget saying one thing.
struct LogDigest {
    struct Subject: Equatable {
        let subsystem: String
        let category: String
        let message: String
        let level: LogRecord.Level
        let count: UInt64
    }

    private struct Key: Hashable {
        let subsystem: String
        let category: String
        let message: String
        let level: String
    }

    let subjects: [Subject]
    /// Distinct subjects the ceiling left out. "Sixteen kinds of problem" and
    /// "sixteen of many" are different findings.
    let omitted: Int

    var isEmpty: Bool {
        subjects.isEmpty
    }

    init(
        _ records: [LogRecord],
        ceiling: Int,
        admitting: (LogRecord) -> Bool = { _ in true }
    ) {
        var counts = [Key: (Subject, UInt64)]()
        for record in records where admitting(record) {
            let key = Key(
                subsystem: record.subsystem,
                category: record.category,
                message: record.message,
                level: record.level.rawValue
            )
            let running = (counts[key]?.1 ?? 0) + 1
            counts[key] = (
                Subject(
                    subsystem: record.subsystem,
                    category: record.category,
                    message: record.message,
                    level: record.level,
                    count: running
                ),
                running
            )
        }

        // By count, then by message. Ordering on arrival would make two captures
        // of the same problem disagree about which line mattered most.
        let ranked = counts.values
            .map { subject, count in
                Subject(
                    subsystem: subject.subsystem,
                    category: subject.category,
                    message: subject.message,
                    level: subject.level,
                    count: count
                )
            }
            .sorted { ($0.count, $1.message) > ($1.count, $0.message) }

        subjects = Array(ranked.prefix(ceiling))
        omitted = max(0, ranked.count - subjects.count)
    }
}

/// Who is logging inside this process and how much, without regard to what they
/// said.
///
/// The discovery half. Nobody can ask for a framework's complaints without
/// knowing it is complaining, and this answers "who is talking" in one reading —
/// the question that comes before every other one in this domain.
struct LogTraffic {
    struct Source: Equatable {
        let subsystem: String
        let category: String
        let count: UInt64
        let diagnostics: UInt64
    }

    private struct Key: Hashable {
        let subsystem: String
        let category: String
    }

    let sources: [Source]
    let omitted: Int
    let total: UInt64

    var isEmpty: Bool {
        sources.isEmpty
    }

    init(_ records: [LogRecord], ceiling: Int) {
        var counts = [Key: (all: UInt64, diagnostic: UInt64)]()
        for record in records {
            let key = Key(subsystem: record.subsystem, category: record.category)
            var running = counts[key] ?? (0, 0)
            running.all += 1
            if record.level.isDiagnostic {
                running.diagnostic += 1
            }
            counts[key] = running
        }

        // Diagnostics first, then volume. A subsystem with one fault is a better
        // lead than one with ten thousand notices, and ranking on volume alone
        // buries it under whatever logs most.
        let ranked = counts
            .map { key, running in
                Source(
                    subsystem: key.subsystem,
                    category: key.category,
                    count: running.all,
                    diagnostics: running.diagnostic
                )
            }
            .sorted {
                ($0.diagnostics, $0.count, $1.subsystem)
                    > ($1.diagnostics, $1.count, $0.subsystem)
            }

        sources = Array(ranked.prefix(ceiling))
        omitted = max(0, ranked.count - sources.count)
        total = UInt64(records.count)
    }
}

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

/// Who is logging inside this process, and how much.
///
/// The question that comes before every other one in this domain. Nobody can ask
/// for a framework's complaints without knowing it is complaining, and no list of
/// subsystems exists anywhere to consult — an app links whatever it links, and
/// each of those logs under names nobody published. This reads the process and
/// says what is actually there.
///
/// Deliberately says nothing about *what* was logged. Volume and severity per
/// subsystem is a map; `log.faults` is what to do with it.
final class LogSubsystems: StreamingInstrument {
    static let id: InstrumentWireID = .logSubsystems
    static let entity = Entity.WireID.logRecord

    private static let sourcesPerFlush = 32

    private let reader: LogStoreReader = .init(subsystems: [])

    init() {}

    static func write(
        _ traffic: LogTraffic,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        for (index, source) in traffic.sources.enumerated() {
            if index == 0 {
                put(source, over: window, into: &out)
                continue
            }
            out.also(entity) { sibling in put(source, over: window, into: &sibling) }
        }

        guard traffic.omitted > 0 else {
            return
        }

        out.also(entity) { sibling in
            sibling.put(.windowNanoseconds(window.nanoseconds))
            sibling.put(.occurrenceCount(traffic.total))
            sibling.put(.mechanismStatus("truncated: \(traffic.omitted) more"))
        }
    }

    private static func put(
        _ source: LogTraffic.Source,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.logSubsystem(source.subsystem))
        out.put(.logCategory(source.category))
        out.put(.occurrenceCount(source.count))
        // How many of that count were errors or faults. Carried apart from the
        // total because a subsystem logging ten thousand notices and one logging
        // a single fault are opposite findings that a single number merges.
        if source.diagnostics > 0 {
            out.put(.detail("diagnostics: \(source.diagnostics)"))
        }
    }

    func observe(_ context: Context) {
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records):
                let traffic = LogTraffic(records, ceiling: Self.sourcesPerFlush)
                guard !traffic.isEmpty else {
                    return
                }

                Self.write(traffic, over: window, into: &out)
            }
        }
    }

    func stopObserving() {}
}
