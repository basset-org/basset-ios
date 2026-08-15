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
        written.bootTimeMicroseconds = 1700000000000000
        written.isSimulator = true
        written.debuggerAttached = true
        written.osVersion = "18.4.0"

        #expect(roundTrip(written) == written)
    }

    /// A record from an old build must not read as current — the user may have updated meanwhile.
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

    /// The version string is a fixed thirty bytes — longer is cut, not left to overrun the next.
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
    /// No clean shutdown here, on purpose — this is the crash case the mechanism exists for.
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
        #expect(
            RunEnding(previous, currentAppVersion: previous.appVersion).reason
                == "ownMemoryLimit"
        )
    }

    /// Opening the file replaces the previous record — a third launch reads the second run.
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

    /// The narrowest fact wins — a run with both a hang and low headroom is named after the hang.
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

    /// Zero headroom is what the kernel writes when it didn't answer — not a sign memory is gone.
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

    /// iOS reclaims backgrounded processes silently — same absence flips meaning in foreground.
    @Test func theSameAbsenceOfEvidenceMeansOppositeThingsByState() {
        var background = healthy()
        background.appState = .background

        #expect(RunEnding(background).reason == "reclaimedWhileBackgrounded")
        #expect(RunEnding(healthy()).reason == "unexpected")
    }

    /// A stale hang reading from before shutdown must not outrank the reboot that explains it.
    @Test func aDifferentBootTimeIsAReboot() {
        var record = starved()
        record.bootTimeMicroseconds = 111

        #expect(
            RunEnding(record, currentBootTimeMicroseconds: 222).reason == "reboot"
        )
    }

    /// Zero means the field predates this run — nothing to compare, so it must not read as a
    /// reboot.
    @Test func aRecordWithNoStampedBootTimeIsNotClaimedAsARebootEitherWay() {
        #expect(
            RunEnding(healthy(), currentBootTimeMicroseconds: 222).reason == "unexpected"
        )
    }

    @Test func aDebuggerAttachedAtTheLastStampOutranksTheMeasuredSignals() {
        var record = starved()
        record.debuggerAttached = true

        #expect(RunEnding(record).reason == "debuggerAttached")
    }

    @Test func anAppVersionThatChangedSinceIsWhyTheOldRunEnded() {
        var record = healthy()
        record.appVersion = "1.0.0"

        #expect(
            RunEnding(record, currentAppVersion: "1.1.0").reason == "appUpdated"
        )
    }

    @Test func anOSVersionThatChangedSinceIsWhyTheOldRunEnded() {
        var record = healthy()
        record.osVersion = "17.0.0"

        #expect(
            RunEnding(record, currentOSVersion: "18.0.0").reason == "osUpdated"
        )
    }

    /// Xcode's Stop button kills a simulator app directly — not the watchdog or jetsam.
    @Test func aForegroundSimulatorRunWithNoMeasuredCauseWasLikelyStoppedByHand() {
        var record = healthy()
        record.isSimulator = true

        #expect(RunEnding(record).reason == "simulatorStopped")
    }

    @Test func aBackgroundedSimulatorRunIsStillReadAsRoutineReclaim() {
        var record = healthy()
        record.appState = .background
        record.isSimulator = true

        #expect(RunEnding(record).reason == "reclaimedWhileBackgrounded")
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
