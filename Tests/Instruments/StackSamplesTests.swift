@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

/// Serialized: each walk suspends every other test's threads, so overlap stacks the windows.
@Suite(
    .serialized,
    .disabled(
        if: ThreadWalker.isThreadSanitizerLoaded,
        "the walker refuses to suspend threads while a sanitizer is loaded"
    )
)
struct MainThreadWalkTests {
    /// Suspending the main thread has to be survivable — this path runs twenty times a second.
    @Test func samplingTheMainThreadLeavesItRunning() async {
        await MainActor.run { MainThreadPort.capture() }
        let walker = ThreadWalker()

        let frames = await Task.detached { walker.walkMainThread() }.value
        let stillScheduling = await MainActor.run { (1...1000).reduce(0, +) }

        #expect(stillScheduling == 500500, "the main thread runs after being suspended")
        #expect(frames != nil, "a captured main thread port is readable")
    }

    @Test func repeatedSamplingStaysStable() async {
        await MainActor.run { MainThreadPort.capture() }
        let walker = ThreadWalker()

        let counts = await Task.detached { () -> [Int] in
            (0 ..< 50).map { _ in walker.walkMainThread()?.count ?? -1 }
        }
        .value

        #expect(counts.allSatisfy { $0 >= 0 }, "every sample read the thread")
        #expect(
            counts.allSatisfy { $0 <= ThreadWalker.maxFrames },
            "no sample runs past the frame cap"
        )
    }

    /// A sampler asking from the main thread would suspend itself and never resume.
    @Test @MainActor func theMainThreadCannotSampleItself() {
        MainThreadPort.capture()

        #expect(ThreadWalker().walkMainThread() == nil)
    }

    /// Refused before ever reaching the lock — an unrelated walk holding it must not be blamed.
    @Test @MainActor func aRefusalBeforeTheLockNeverReportsItAsTimedOut() {
        MainThreadPort.capture()
        var lockTimedOut = true

        let frames = ThreadWalker().walkMainThread(reportingLockTimeout: &lockTimedOut)

        #expect(frames == nil)
        #expect(lockTimedOut == false)
    }

    /// A full walk and a sample share a lock; a failure here is a hang, not a wrong answer.
    @Test func samplingConcurrentlyWithAFullWalkFinishes() async {
        await MainActor.run { MainThreadPort.capture() }

        await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 12 {
                group.addTask {
                    if index.isMultiple(of: 3) {
                        return !ThreadWalker().walk().isEmpty
                    }

                    return ThreadWalker().walkMainThread() != nil
                }
            }
            var completed = 0
            for await _ in group {
                completed += 1
            }
            #expect(completed == 12, "every walk and every sample finished")
        }
    }
}

struct BinaryImageLookupTests {
    @Test func anAddressResolvesToTheImageItLandedIn() throws {
        let executable = try #require(BinaryImages.mainExecutable())

        let covering = BinaryImages.covering([executable.loadAddress])

        #expect(covering.map(\.uuid) == [executable.uuid])
    }

    @Test func anAddressInNoMappingResolvesToNothing() {
        #expect(BinaryImages.covering([1, 2, UInt64.max]).isEmpty)
    }

    @Test func eachImageIsReportedOnceHoweverManyAddressesLandInIt() throws {
        let executable = try #require(BinaryImages.mainExecutable())
        try #require(executable.size > 4)

        let inside = (0 ..< 4).map { executable.loadAddress + UInt64($0) }

        #expect(BinaryImages.covering(inside).count == 1)
    }

    /// One call rather than one per image — `covering` re-reads dyld on every call.
    @Test func everyLoadAddressResolvesToItsOwnImage() {
        let mapped = BinaryImages.loaded().filter { $0.size > 0 }

        let found = BinaryImages.covering(mapped.map(\.loadAddress))

        #expect(Set(found.map(\.uuid)) == Set(mapped.map(\.uuid)))
    }
}

struct StackWindowTests {
    @Test func identicalStacksBecomeOneEntryWithACount() {
        var window = StackWindow()

        window.record([0x1000, 0x2000])
        window.record([0x1000, 0x2000])
        window.record([0x1000, 0x2000])
        window.record([0x9000])

        #expect(window.hottest.map(\.hits) == [3, 1])
        #expect(window.hottest.first?.frames == [0x1000, 0x2000])
        #expect(window.samplesTaken == 4)
    }

    /// Counting on the innermost frame alone would merge everything through the run loop.
    @Test func stacksSharingAPrefixAreNotOneStack() {
        var window = StackWindow()

        window.record([0x10, 0x20, 0x30])
        window.record([0x10, 0x20])

        #expect(window.hottest.count == 2)
    }

    @Test func orderMattersSoAReversedStackIsADifferentStack() {
        var window = StackWindow()

        window.record([0x10, 0x20])
        window.record([0x20, 0x10])

        #expect(window.hottest.count == 2)
    }

    @Test func aSampleThatUnwoundNothingIsCountedRatherThanDropped() {
        var window = StackWindow()

        window.record([0x1000])
        window.record([])
        window.record([])

        #expect(window.samplesTaken == 3)
        #expect(window.withoutStack == 2)
        #expect(window.hottest.count == 1)
    }

    /// A sample the walker refused is not a sample of an idle thread — excluded from both counts.
    @Test func anUnreadableThreadIsCountedApartFromTheSamplesTaken() {
        var window = StackWindow()

        window.record(nil)
        window.record(nil)

        #expect(window.unreadable == 2)
        #expect(window.samplesTaken == 0)
        #expect(window.withoutStack == 0)
    }

    /// Carried from the sample that actually found the lock held, not read again later.
    @Test func aLockFoundHeldAtTheTimeOfTheSampleIsRemembered() {
        var window = StackWindow()

        window.record(nil, exclusiveHeld: true)

        #expect(window.lockTimedOut)
    }

    @Test func anUnreadableSampleWithTheLockFreeIsNotMistakenForATimeout() {
        var window = StackWindow()

        window.record(nil, exclusiveHeld: false)

        #expect(window.lockTimedOut == false)
    }
}

struct StackSampleReadingTests {
    @Test func theHottestStackLeadsAndEachAdditionalEntityCarriesItsOwnCount() {
        var window = StackWindow()
        for _ in 0 ..< 7 {
            window.record([0x1000])
        }
        window.record([0x2000])

        let readings = emit(window)

        let counts = readings
            .filter { $0.id == .stackSample }
            .compactMap { count(of: .occurrenceCount, in: $0) }
        #expect(counts == [7, 1], "hottest first, each with its own count")
    }

    /// The window total rides each stack's own reading — the additional entity holding it may be
    /// trimmed.
    @Test func everyStackCarriesTheWindowTotalOfItsOwn() {
        var window = StackWindow()
        for _ in 0 ..< 5 {
            window.record([0x1000])
        }
        window.record([0x2000])

        let readings = emit(window)

        for reading in readings where reading.id == .stackSample {
            #expect(count(of: .sampleCount, in: reading) == 6)
        }
    }

    /// Silence would read as an idle app, the opposite of every sample failing to unwind.
    @Test func aWindowWhereNothingUnwoundStillReports() {
        var window = StackWindow()
        window.record([])
        window.record([])

        let readings = emit(window)

        #expect(count(of: .sampleCount, in: readings.first) == 2)
        #expect(count(of: .unwindFailureCount, in: readings.first) == 2)
        #expect(readings.allSatisfy { rendered(.frameAddress, in: $0) == nil })
    }

    @Test func aWindowThatSampledNothingSaysNothing() {
        #expect(emit(StackWindow()).isEmpty)
    }

    /// A sanitizer refusal must not read as a missing main thread — different fixes.
    @Test func theUnreadableStatusNamesTheSanitizerWhenOneIsLoaded() {
        #expect(StackSamples.unreadableStatus(sanitizerLoaded: true)
            == "unavailable: a thread sanitizer is loaded")
        #expect(StackSamples.unreadableStatus(sanitizerLoaded: false)
            == "unavailable: no main thread has been identified")
    }

    /// A timed-out lock must not read as a missing main thread either — the main thread exists.
    @Test func theUnreadableStatusNamesAHeldLockRatherThanAMissingMainThread() {
        #expect(
            StackSamples.unreadableStatus(sanitizerLoaded: false, exclusiveHeld: true)
                == "unavailable: another walk held the lock past its timeout"
        )
        #expect(
            StackSamples.unreadableStatus(sanitizerLoaded: true, exclusiveHeld: true)
                == "unavailable: a thread sanitizer is loaded"
        )
    }

    /// No main thread to read is a broken mechanism, distinct from a quiet one.
    @Test func aWindowThatCouldNotReadTheMainThreadSaysSo() {
        var window = StackWindow()
        window.record(nil)

        let readings = emit(window)

        #expect(readings.count == 1)
        #expect(rendered(.mechanismStatus, in: readings[0])?.contains("unavailable") == true)
        #expect(rendered(.sampleCount, in: readings[0]) == nil)
    }

    /// The window carries what the sampling thread saw — a flush reading the lock again, later
    /// and off that thread, would usually find a genuinely timed-out holder already gone.
    @Test func aWindowWhereTheLockWasFoundHeldReportsTheTimeoutRatherThanAMissingThread() {
        var window = StackWindow()
        window.record(nil, exclusiveHeld: true)

        let readings = emit(window)

        // A sanitizer still outranks it live, same as everywhere else this status is read.
        let expected = ThreadWalker.isThreadSanitizerLoaded
            ? "unavailable: a thread sanitizer is loaded"
            : "unavailable: another walk held the lock past its timeout"
        #expect(rendered(.mechanismStatus, in: readings[0]) == expected)
    }

    @Test func moreDistinctStacksThanTheCapReportTheTruncation() {
        var window = StackWindow()
        for index in 0 ..< 12 {
            window.record([UInt64(0x1000 + index)])
        }

        let readings = emit(window)

        let truncation = readings
            .compactMap { rendered(.mechanismStatus, in: $0) }
            .first { $0.hasPrefix("truncated") }
        #expect(truncation == "truncated: 4 more")
        #expect(readings.filter { rendered(.frameAddress, in: $0) != nil }.count
            == StackSamples.stacksPerWindow)
    }

    /// Frames carry no index — write order is the only thing preserving stack order.
    @Test func framesKeepTheirOrderInnermostFirst() {
        var window = StackWindow()
        window.record([0x30, 0x20, 0x10])

        let frames = emit(window)
            .flatMap(\.components)
            .filter { $0.id == .frameAddress }
            .map(\.value.rendered)

        #expect(frames == ["48", "32", "16"])
    }

    /// The images an address lands in are the runner's to send, once per request — a
    /// window here carries the addresses and nothing else.
    @Test func areportedStackCarriesAddressesAndLeavesTheImagesToTheRunner() throws {
        let executable = try #require(BinaryImages.mainExecutable())
        var window = StackWindow()
        window.record([executable.loadAddress])

        let readings = emit(window)

        #expect(readings.contains { $0.id == .stackSample })
        #expect(!readings.contains { $0.id == .binaryImage })
    }

    private func emit(_ window: StackWindow) -> [Entity] {
        var out = Readings(.stackSample)
        StackSamples(config: StackSamples.defaultConfig).write(
            window,
            over: Context.FlushWindow(nanoseconds: 1000000000),
            into: &out
        )
        guard !out.isEmpty else {
            return []
        }

        return [out.build()] + out.additionalEntities()
    }

    private func rendered(_ id: Component.ID, in entity: Entity?) -> String? {
        entity?.components.first { $0.id == id }?.value.rendered
    }

    private func count(of id: Component.ID, in entity: Entity?) -> UInt64? {
        rendered(id, in: entity).flatMap(UInt64.init)
    }
}

struct StackSamplesConfigTests {
    /// Unclamped, a 0ms interval sleeps for nothing and the sampling loop busy-spins.
    @Test func aZeroIntervalIsClampedRatherThanBusySpinning() {
        let instrument = StackSamples(config: .init(intervalMs: 0))
        #expect(instrument.interval == 0.01)
    }

    @Test func aHugeIntervalIsClampedToASecond() {
        let instrument = StackSamples(config: .init(intervalMs: .max))
        #expect(instrument.interval == 1)
    }

    @Test func anOrdinaryIntervalPassesThroughUnchanged() {
        let instrument = StackSamples(config: .init(intervalMs: 100))
        #expect(instrument.interval == 0.1)
    }

    /// The clamp and the schema a caller reads before it must never quietly disagree.
    @Test func theClampMatchesItsOwnDeclaredMetadataRange() throws {
        let field = try #require(
            InstrumentID.stackSamples.metadata.config.first { $0.key == "intervalMs" }
        )
        let range = try #require(field.type.intRange)

        let lowest = StackSamples(config: .init(intervalMs: .min))
        let highest = StackSamples(config: .init(intervalMs: .max))
        #expect(lowest.interval == Double(range.lowerBound) / 1000)
        #expect(highest.interval == Double(range.upperBound) / 1000)
    }
}
