@testable import Basset
import Foundation
import Testing

struct LogDigestTests {
    /// A framework in a bad state repeats one line thousands of times. The useful
    /// shape is the line and its count, not the line a thousand times.
    @Test func repeatsOfOneLineBecomeOneSubjectWithACount() {
        let digest = LogDigest(
            [
                record("failed to connect"),
                record("failed to connect"),
                record("timed out"),
            ],
            ceiling: 10
        )

        #expect(digest.subjects.count == 2)
        #expect(digest.subjects.first?.message == "failed to connect")
        #expect(digest.subjects.first?.count == 2)
    }

    /// Two captures of the same problem must agree about which line mattered
    /// most, so ranking is on the count and then the message — never on arrival.
    @Test func rankingDoesNotDependOnArrivalOrder() {
        let forwards = LogDigest([record("a"), record("b"), record("b")], ceiling: 10)
        let backwards = LogDigest([record("b"), record("b"), record("a")], ceiling: 10)

        #expect(forwards.subjects.map(\.message) == backwards.subjects.map(\.message))
        #expect(forwards.subjects.first?.message == "b")
    }

    /// The same message at two levels is two findings. An error and a notice that
    /// read alike are not the same event.
    @Test func theSameTextAtTwoLevelsIsNotOneSubject() {
        let digest = LogDigest(
            [record("stalled", level: .error), record("stalled", level: .notice)],
            ceiling: 10
        )

        #expect(digest.subjects.count == 2)
    }

    /// "Sixteen kinds of problem" and "sixteen of many" are different findings,
    /// and a capture that cannot tell them apart is misleading.
    @Test func whatTheCeilingLeftOutIsCountedRatherThanDropped() {
        let digest = LogDigest((0 ..< 10).map { record("line \($0)") }, ceiling: 4)

        #expect(digest.subjects.count == 4)
        #expect(digest.omitted == 6)
    }

    @Test func theAdmissionRuleDecidesWhatIsCountedAtAll() {
        let records = [record("bad", level: .fault), record("fine", level: .info)]
        let everything = LogDigest(records, ceiling: 10)
        let diagnosticsOnly = LogDigest(
            records,
            ceiling: 10,
            admitting: { $0.level.isDiagnostic }
        )

        #expect(everything.subjects.count == 2)
        #expect(diagnosticsOnly.subjects.count == 1)
        #expect(diagnosticsOnly.subjects.first?.message == "bad")
    }

    private func record(
        _ message: String,
        level: LogRecord.Level = .error,
        subsystem: String = "com.apple.network"
    ) -> LogRecord {
        LogRecord(
            subsystem: subsystem,
            category: "connection",
            message: message,
            level: level,
            date: Date(timeIntervalSince1970: 0)
        )
    }
}

struct LogTrafficTests {
    /// A subsystem with one fault is a better lead than one with ten thousand
    /// notices. Ranking on volume alone buries the finding under whatever logs
    /// most, which on iOS is never the thing that is broken.
    @Test func oneFaultOutranksAFloodOfNotices() {
        var records = (0 ..< 500).map { record(
            "chatty",
            level: .notice,
            message: "line \($0)"
        ) }
        records.append(record("quiet", level: .fault, message: "it broke"))

        let traffic = LogTraffic(records, ceiling: 10)

        #expect(traffic.sources.first?.subsystem == "quiet")
        #expect(traffic.sources.first?.diagnostics == 1)
    }

    @Test func aSubsystemsLinesAreCountedTogetherAcrossMessages() {
        let traffic = LogTraffic(
            [
                record("com.apple.network", message: "one"),
                record("com.apple.network", message: "two"),
                record("com.apple.coredata", message: "three"),
            ],
            ceiling: 10
        )

        #expect(traffic.total == 3)
        #expect(traffic.sources.count == 2)
        #expect(traffic.sources.first { $0.subsystem == "com.apple.network" }?.count == 2)
    }

    /// Same subsystem, different category, is two rows: a subsystem's categories
    /// are what separate its ordinary chatter from its failures.
    @Test func categoriesWithinASubsystemAreKeptApart() {
        let traffic = LogTraffic(
            [
                record("com.apple.network", category: "connection"),
                record("com.apple.network", category: "resolver"),
            ],
            ceiling: 10
        )

        #expect(traffic.sources.count == 2)
    }

    private func record(
        _ subsystem: String,
        category: String = "general",
        level: LogRecord.Level = .notice,
        message: String = "line"
    ) -> LogRecord {
        LogRecord(
            subsystem: subsystem,
            category: category,
            message: message,
            level: level,
            date: Date(timeIntervalSince1970: 0)
        )
    }
}
