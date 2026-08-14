@testable import Basset
import Foundation
import OSLog
import Testing

struct LogDigestTests {
    /// A framework in a bad state repeats one line thousands of times — count it, don't repeat.
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

    /// Redacted before grouping, or per-user variants each take a slot the ceiling then denies.
    @Test func messagesDifferingOnlyInATokenBecomeOneSubject() {
        let digest = LogDigest(
            [
                record("checkout failed for jeff@example.com"),
                record("checkout failed for amy@example.com"),
            ],
            ceiling: 10
        )

        #expect(digest.subjects.count == 1)
        #expect(digest.subjects.first?.message == "checkout failed for :id")
        #expect(digest.subjects.first?.count == 2)
    }

    /// Ranking is by count then message, never arrival — two captures must agree on it.
    @Test func rankingDoesNotDependOnArrivalOrder() {
        let forwards = LogDigest([record("a"), record("b"), record("b")], ceiling: 10)
        let backwards = LogDigest([record("b"), record("b"), record("a")], ceiling: 10)

        #expect(forwards.subjects.map(\.message) == backwards.subjects.map(\.message))
        #expect(forwards.subjects.first?.message == "b")
    }

    /// An error and a notice with identical text are two findings, not one.
    @Test func theSameTextAtTwoLevelsIsNotOneSubject() {
        let digest = LogDigest(
            [record("stalled", level: .error), record("stalled", level: .notice)],
            ceiling: 10
        )

        #expect(digest.subjects.count == 2)
    }

    /// "Sixteen kinds of problem" and "sixteen of many" differ — the omitted count says which.
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
    /// Volume alone buries the finding — what logs most on iOS is never the broken thing.
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

    /// Categories separate a subsystem's chatter from its failures — kept as separate rows.
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

/// Against the real store — the ceiling is a budget, and what it's spent on decides what is seen.
@Suite(.serialized)
struct LogStoreReaderTests {
    private static let subsystem = "dev.basset.tests.logstore"

    /// Empty means the store won't hand this process its own records — a machine fact, not a bug.
    private static func storeAnswers(since: Date) -> Bool {
        let unfiltered = LogStoreReader(
            subsystems: [subsystem],
            since: since,
            ceiling: 100
        )
        guard case .read(let records, _) = unfiltered.drain() else {
            return false
        }

        return !records.isEmpty
    }

    @Test func theceilingIsSpentOnRecordsTheCallerAdmits() {
        let noisy = Logger(subsystem: Self.subsystem, category: "noise")
        let since = Date()

        // More notices than the ceiling — a naive "first N" reader fills before faults arrive.
        for index in 0 ..< 40 {
            noisy.notice("basset test notice \(index, privacy: .public)")
        }
        for index in 0 ..< 3 {
            noisy.fault("basset test fault \(index, privacy: .public)")
        }

        // Checked before filtering — a GitHub runner answers no, not the reader dropping faults.
        guard Self.storeAnswers(since: since) else {
            return
        }

        let reader = LogStoreReader(
            subsystems: [Self.subsystem],
            since: since,
            ceiling: 20,
            admitting: { $0.level.isDiagnostic }
        )

        guard case .read(let records, _) = reader.drain() else {
            return
        }

        let refused = records.filter { !$0.level.isDiagnostic }
        #expect(refused.isEmpty, "a record the reader was told to refuse came back")

        // No emptiness guard — empty is exactly the failure mode this test exists to catch.
        let faults = records.filter { $0.level == .fault }
        #expect(
            !faults.isEmpty,
            "forty notices preceded three faults and the read carried none of them"
        )
    }

    @Test func acutReadSaysSoRatherThanLookingComplete() {
        let chatty = Logger(subsystem: Self.subsystem, category: "flood")
        let since = Date()
        for index in 0 ..< 30 {
            chatty.error("basset test error \(index, privacy: .public)")
        }

        guard Self.storeAnswers(since: since) else {
            return
        }

        let reader = LogStoreReader(
            subsystems: [Self.subsystem],
            since: since,
            ceiling: 5
        )

        guard case .read(let records, let cutShort) = reader.drain() else {
            return
        }
        guard records.count >= 5 else {
            return
        }

        #expect(cutShort, "the read stopped on its ceiling and did not say so")
    }
}

struct LogSubsystemFilterTests {
    @Test func logFaultsScopesTheReaderToTheConfiguredSubsystem() {
        let instrument = LogFaults(config: .init(subsystem: "com.example.foo"))
        #expect(instrument.reader.subsystems == ["com.example.foo"])
    }

    @Test func logFaultsWithNoSubsystemReadsEverything() {
        let instrument = LogFaults(config: .init(subsystem: nil))
        #expect(instrument.reader.subsystems == [])
    }

    @Test func logSubsystemsScopesTheReaderToTheConfiguredSubsystem() {
        let instrument = LogSubsystems(config: .init(subsystem: "com.example.foo"))
        #expect(instrument.reader.subsystems == ["com.example.foo"])
    }

    @Test func logSubsystemsWithNoSubsystemReadsEverything() {
        let instrument = LogSubsystems(config: .init(subsystem: nil))
        #expect(instrument.reader.subsystems == [])
    }
}
