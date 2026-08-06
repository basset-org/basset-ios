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
