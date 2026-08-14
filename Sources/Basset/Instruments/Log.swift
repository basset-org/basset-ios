import BassetECS
import Foundation

/// Log records grouped by what they say, counted and ranked — testable without a log store.
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
    /// Distinct subjects the ceiling left out — "sixteen kinds" and "sixteen of many" differ.
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
            // Scrubbed before grouping: two messages differing only in a token merge into
            // one row rather than each taking a slot the ceiling then denies a real fault.
            let message = Redaction.message(record.message)
            let key = Key(
                subsystem: record.subsystem,
                category: record.category,
                message: message,
                level: record.level.rawValue
            )
            let running = (counts[key]?.1 ?? 0) + 1
            counts[key] = (
                Subject(
                    subsystem: record.subsystem,
                    category: record.category,
                    message: message,
                    level: record.level,
                    count: running
                ),
                running
            )
        }

        // By count then message — ordering on arrival would make two captures disagree.
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
            // Total order — otherwise a tied subject drops differently each capture.
            .sorted {
                ($0.count, $1.message, $1.subsystem, $1.category, $1.level.rawValue)
                    > ($1.count, $0.message, $0.subsystem, $0.category, $0.level.rawValue)
            }

        subjects = Array(ranked.prefix(ceiling))
        omitted = max(0, ranked.count - subjects.count)
    }
}

/// Who is logging and how much, without regard to what they said.
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

        // Diagnostics first, then volume — a lone fault beats ten thousand notices as a lead.
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
                ($0.diagnostics, $0.count, $1.subsystem, $1.category)
                    > ($1.diagnostics, $1.count, $0.subsystem, $0.category)
            }

        sources = Array(ranked.prefix(ceiling))
        omitted = max(0, ranked.count - sources.count)
        total = UInt64(records.count)
    }
}

/// Shared by every `log.*` instrument that can be scoped to one subsystem instead of all of them.
struct LogSubsystemFilter: Codable, Sendable {
    /// Matches the maxLength declared on this field's `InstrumentMetadata.ConfigField`.
    private static let maximumSubsystemLength = 256

    let subsystem: String?

    /// A blank subsystem reads as none; an oversized value is truncated to stay bounded.
    var subsystems: [String] {
        guard let subsystem, !subsystem.isEmpty else {
            return []
        }

        return [String(subsystem.prefix(Self.maximumSubsystemLength))]
    }
}

/// A message can carry what an app logged as public; token-shaped runs are scrubbed out.
final class LogFaults: Streamable, Configurable {
    static let id: InstrumentID = .logFaults
    static let entity = Entity.ID.logRecord
    static let defaultConfig: LogSubsystemFilter = .init(subsystem: nil)

    private static let subjectsPerFlush = 24

    /// Refused while scanning, not after — a chatty subsystem would crowd out real faults.
    let reader: LogStoreReader

    init(config: LogSubsystemFilter) {
        reader = LogStoreReader(subsystems: config.subsystems, admitting: { $0.level.isDiagnostic })
    }

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
        // On every row, not only the first — a sibling count needs it to divide by.
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.logSubsystem(subject.subsystem))
        out.put(.logCategory(subject.category))
        out.put(.logMessage(subject.message))
        out.put(.logLevel(subject.level.rawValue))
        out.put(.occurrenceCount(subject.count))
    }

    func observe(_ context: Context) {
        // 15s: an OSLogStore drain measured ~10s on device regardless of what's read.
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records, let cutShort):
                let digest = LogDigest(records, ceiling: Self.subjectsPerFlush)
                guard !digest.isEmpty else {
                    return
                }

                Self.write(digest, over: window, into: &out)
                guard cutShort else {
                    return
                }

                out.also(Self.entity) { sibling in
                    sibling.put(.windowNanoseconds(window.nanoseconds))
                    sibling.put(
                        .mechanismStatus("read stopped on its ceiling; more unread")
                    )
                }
            }
        }
    }

    func stopObserving() {}
}

/// Who is logging and how much — no subsystem list exists, so this reads the process itself.
final class LogSubsystems: Streamable, Configurable {
    static let id: InstrumentID = .logSubsystems
    static let entity = Entity.ID.logRecord
    static let defaultConfig: LogSubsystemFilter = .init(subsystem: nil)

    private static let sourcesPerFlush = 32

    let reader: LogStoreReader

    init(config: LogSubsystemFilter) {
        reader = LogStoreReader(subsystems: config.subsystems)
    }

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
        // Apart from the total — ten thousand notices and one fault are opposite findings.
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
            case .read(let records, let cutShort):
                let traffic = LogTraffic(records, ceiling: Self.sourcesPerFlush)
                guard !traffic.isEmpty else {
                    return
                }

                Self.write(traffic, over: window, into: &out)
                guard cutShort else {
                    return
                }

                // A cut read describes the start of the window, not the whole thing.
                out.also(Self.entity) { sibling in
                    sibling.put(.windowNanoseconds(window.nanoseconds))
                    sibling.put(
                        .mechanismStatus("read stopped on its ceiling; more unread")
                    )
                }
            }
        }
    }

    func stopObserving() {}
}
