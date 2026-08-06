import Foundation

/// What a window of log records says, separated from the reading of them.
///
/// A re-render loop repeats one violation thousands of times a second, so the
/// useful shape is "this rule broke, this many times" rather than one reading
/// per occurrence. Pure, so the rule can be tested on the host without a log
/// store to read from.
struct RuntimeIssueDigest {
    struct Subject: Equatable {
        let subsystem: String
        let category: String
        let message: String
        let count: UInt64
    }

    private struct Key: Hashable {
        let subsystem: String
        let category: String
        let message: String
    }

    static let admittedSwiftUICategories: Set<String> = ["Changed Body Properties"]

    let subjects: [Subject]
    /// Distinct subjects the ceiling left out. Reported rather than dropped
    /// quietly: "sixteen kinds of problem" and "sixteen of many" are different
    /// findings, and a capture that cannot tell them apart is misleading.
    let omitted: Int

    var isEmpty: Bool {
        subjects.isEmpty
    }

    init(_ records: [LogRecord], ceiling: Int) {
        let admitted = records.filter(Self.admits)

        var counts = [Key: UInt64]()
        for record in admitted {
            counts[
                Key(
                    subsystem: record.subsystem,
                    category: record.category,
                    message: record.message
                ),
                default: 0
            ] += 1
        }

        // By count, then by message. Ordering on arrival would make two captures
        // of the same bug disagree about which violation mattered most.
        let ranked =
            counts
                .map {
                    Subject(
                        subsystem: $0.key.subsystem,
                        category: $0.key.category,
                        message: $0.key.message,
                        count: $0.value
                    )
                }
                .sorted {
                    ($0.count, $1.message) > ($1.count, $0.message)
                }

        subjects = Array(ranked.prefix(ceiling))
        omitted = max(0, ranked.count - subjects.count)
    }

    /// Severity first, because a subsystem is not uniformly diagnostic.
    ///
    /// `com.apple.attributegraph` carries the non-fatal precondition failures
    /// worth reading *and* lines like "ignoring retroactive Equatable conformance
    /// on type __C.AGAttribute". Filtering on level rather than on a category
    /// deny-list keeps the one and drops the other without having to know every
    /// category Apple might add.
    ///
    /// `com.apple.runtime-issues` exists only to carry them, so its level does
    /// not need checking. `com.apple.SwiftUI` is ordinary framework logging with
    /// one category worth reading, and `_logChanges()` emits it at `.info` —
    /// below the severity bar, which is why that one is named explicitly.
    static func admits(_ record: LogRecord) -> Bool {
        switch record.subsystem {
        case "com.apple.runtime-issues": true
        case "com.apple.SwiftUI": admittedSwiftUICategories.contains(record.category)
        default: record.level.isDiagnostic
        }
    }
}
