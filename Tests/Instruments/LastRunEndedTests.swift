@testable import Basset
import Foundation
import Testing

struct RunRecordTests {
    @Test func everyFieldSurvivesTheRoundTrip() {
        var written = RunRecord()
        written.launchId = 0x0102030405060708
        written.startedAtMicroseconds = 1000000
        written.recordedAtMicroseconds = 9000000
        written.memoryUsedBytes = 412000000
        written.memoryAvailableBytes = 8000000
        written.mainUnresponsiveNanoseconds = 7000000000
        written.pressureRecordedAtMicroseconds = 8900000
        written.appState = .background
        written.pressureLevel = .critical
        written.cleanExit = true
        written.appVersion = "4.2.0"

        #expect(roundTrip(written) == written)
    }

    /// A record left by a build that is no longer installed must not be read as
    /// this format. The run that writes and the run that reads can be two
    /// different builds — the user updated in between.
    @Test func anythingThatIsNotThisFormatIsRefused() {
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: RunRecord.size,
            alignment: 8
        )
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: RunRecord.size)

        #expect(RunRecord.decode(UnsafeRawPointer(bytes)) == nil)

        var record = RunRecord()
        record.appVersion = "1.0"
        record.encode(into: bytes)
        bytes.storeBytes(of: UInt16(999), toByteOffset: 4, as: UInt16.self)

        #expect(RunRecord.decode(UnsafeRawPointer(bytes)) == nil)
    }

    /// The version string is a fixed thirty bytes. A longer one is cut rather
    /// than allowed to run into the next field.
    @Test func anOverlongVersionIsTruncatedAndNothingAfterItMoves() {
        var written = RunRecord()
        written.appVersion = String(repeating: "9", count: 200)
        written.launchId = 42

        let read = roundTrip(written)

        #expect(read?.appVersion.count == 30)
        #expect(read?.launchId == 42)
    }

    @Test func theRecordFitsTheSpaceItClaims() {
        var written = RunRecord()
        written.appVersion = String(repeating: "x", count: 30)

        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: RunRecord.size * 2,
            alignment: 8
        )
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0xaa, count: RunRecord.size * 2)
        written.encode(into: bytes)

        let guardByte = bytes.loadUnaligned(
            fromByteOffset: RunRecord.size,
            as: UInt8.self
        )
        #expect(guardByte == 0xaa)
    }

    private func roundTrip(_ record: RunRecord) -> RunRecord? {
        let bytes = UnsafeMutableRawPointer.allocate(
            byteCount: RunRecord.size,
            alignment: 8
        )
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: RunRecord.size)
        record.encode(into: bytes)
        return RunRecord.decode(UnsafeRawPointer(bytes))
    }
}

struct RunRecordFileTests {
    /// The whole mechanism in one test: a run writes, dies without warning, and
    /// the next run reads what it left. No clean shutdown happens anywhere here,
    /// because none happens in the case this exists for.
    @Test func thenextLaunchReadsWhatTheLastOneLeft() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var opening = RunRecord()
        opening.launchId = 7
        opening.appState = .foreground
        opening.appVersion = "1.2.3"

        let first = try #require(RunRecordFile(at: url, startedBy: opening))
        #expect(first.previous == nil)
        first.stamp { record in
            record.memoryUsedBytes = 900000000
            record.memoryAvailableBytes = 2000000
            record.recordedAtMicroseconds = 5000000
        }

        var relaunch = RunRecord()
        relaunch.launchId = 8
        let second = try #require(RunRecordFile(at: url, startedBy: relaunch))

        let previous = try #require(second.previous)
        #expect(previous.launchId == 7)
        #expect(previous.memoryAvailableBytes == 2000000)
        #expect(previous.appVersion == "1.2.3")
        #expect(RunEnding(previous).reason == "ownMemoryLimit")
    }

    /// Opening the file replaces the previous run's record, so a third launch
    /// reads the second run rather than the first.
    @Test func openingReplacesWhatItRead() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var first = RunRecord()
        first.launchId = 1
        _ = RunRecordFile(at: url, startedBy: first)

        var second = RunRecord()
        second.launchId = 2
        _ = RunRecordFile(at: url, startedBy: second)

        var third = RunRecord()
        third.launchId = 3
        let file = try #require(RunRecordFile(at: url, startedBy: third))

        #expect(file.previous?.launchId == 2)
    }

    private func temporaryURL() -> URL {
        FileManager.default
            .temporaryDirectory
            .appendingPathComponent("basset-run-record-\(UUID().uuidString)")
    }
}

struct RunEndingTests {
    @Test func anAnnouncedTerminationOutranksEveryOtherSignal() {
        var record = starved()
        record.cleanExit = true

        #expect(RunEnding(record).reason == "clean")
    }

    /// A stuck main thread is the narrowest fact available, so a run that shows
    /// both a hang and low headroom is named after the hang.
    @Test func aStuckMainThreadOutranksLowHeadroom() {
        var record = starved()
        record.mainUnresponsiveNanoseconds = RunEnding.watchdogThreshold

        #expect(RunEnding(record).reason == "watchdog")
    }

    @Test func aHangShorterThanTheThresholdIsNotAWatchdogKill() {
        var record = healthy()
        record.mainUnresponsiveNanoseconds = RunEnding.watchdogThreshold - 1

        #expect(RunEnding(record).reason == "unexpected")
    }

    @Test func headroomNearlyGoneIsTheAppsOwnLimit() {
        #expect(RunEnding(starved()).reason == "ownMemoryLimit")
    }

    /// Zero headroom is what the kernel writes when it did not answer, so it must
    /// not be read as no memory left — the mistake `MemoryLedger` refuses to make
    /// one level down.
    @Test func unknownHeadroomIsNotReadAsExhaustedHeadroom() {
        var record = healthy()
        record.memoryAvailableBytes = 0

        #expect(RunEnding(record).reason == "unexpected")
    }

    @Test func systemPressureCountsOnlyWhileItIsStillCurrent() {
        var current = healthy()
        current.pressureLevel = .critical
        current.pressureRecordedAtMicroseconds =
            current.recordedAtMicroseconds - RunEnding.pressureRelevanceMicroseconds

        var stale = current
        stale.pressureRecordedAtMicroseconds =
            stale.recordedAtMicroseconds - RunEnding.pressureRelevanceMicroseconds - 1

        #expect(RunEnding(current).reason == "systemMemoryPressure")
        #expect(RunEnding(stale).reason == "unexpected")
    }

    /// iOS reclaims suspended processes constantly and tells nobody, so a
    /// backgrounded run that simply stops is the ordinary case. In the
    /// foreground the same absence of evidence means the opposite.
    @Test func theSameAbsenceOfEvidenceMeansOppositeThingsByState() {
        var background = healthy()
        background.appState = .background

        #expect(RunEnding(background).reason == "reclaimedWhileBackgrounded")
        #expect(RunEnding(healthy()).reason == "unexpected")
    }

    @Test func theRunDurationIsOnlyOfferedWhenItIsPositive() {
        var forwards = healthy()
        forwards.startedAtMicroseconds = 1000
        forwards.recordedAtMicroseconds = 3000

        var backwards = forwards
        backwards.recordedAtMicroseconds = 500

        #expect(RunEnding(forwards).runDurationNanoseconds == 2000000)
        #expect(RunEnding(backwards).runDurationNanoseconds == nil)
    }

    private func healthy() -> RunRecord {
        var record = RunRecord()
        record.appState = .foreground
        record.startedAtMicroseconds = 1000000
        record.recordedAtMicroseconds = 60000000
        record.memoryUsedBytes = 200000000
        record.memoryAvailableBytes = 900000000
        return record
    }

    private func starved() -> RunRecord {
        var record = healthy()
        record.memoryAvailableBytes = RunEnding.exhaustedHeadroomBytes - 1
        return record
    }
}
