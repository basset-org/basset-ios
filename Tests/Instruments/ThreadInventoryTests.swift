@testable import Basset
import BassetECS
import Foundation
import Testing

struct ThreadInventoryReadTests {
    /// Reads the process this test is running in, so it exercises the real Mach
    /// calls rather than a fixture. Every process has a main thread, so an empty
    /// answer is a broken read rather than a quiet one.
    @Test func theProcessDescribesItsOwnThreads() {
        let samples = ThreadInventory.read()

        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.identifier != 0 })
        #expect(samples.allSatisfy { !$0.runState.hasPrefix("unrecognised") })
    }

    /// Two reads a moment apart must not disagree about which threads exist by
    /// more than the threads that actually came and went — and the ids must be
    /// stable, because everything that computes a rate pairs on them.
    @Test func threadIdentifiersAreStableBetweenReads() {
        let first = ThreadInventory.read()
        let second = ThreadInventory.read()

        let shared = Set(first.map(\.identifier)).intersection(second.map(\.identifier))
        #expect(!shared.isEmpty)
    }

    /// CPU time only ever accumulates. A thread whose total went backwards means
    /// the field is being read at the wrong offset, which is the failure that
    /// produces confident nonsense rather than an error.
    @Test func cpuTimeNeverGoesBackwards() {
        let before = Dictionary(
            ThreadInventory.read().map { ($0.identifier, $0.cpuNanoseconds) },
            uniquingKeysWith: { first, _ in first }
        )
        var sink: UInt64 = 0
        for value in 0 ..< 2000000 {
            sink = sink &+ UInt64(value)
        }
        #expect(sink > 0)

        for sample in ThreadInventory.read() {
            guard let earlier = before[sample.identifier] else {
                continue
            }

            #expect(sample.cpuNanoseconds >= earlier)
        }
    }

    /// A boost is the scheduler running a thread above what it asked for. The
    /// plain case must not report one, or the interesting case is unreadable.
    @Test func aThreadAtItsOwnPriorityIsNotReportedAsBoosted() {
        let plain = sample(currentPriority: 31, basePriority: 31)
        let boosted = sample(currentPriority: 47, basePriority: 31)

        #expect(plain.isPriorityBoosted == false)
        #expect(boosted.isPriorityBoosted)
    }

    private func sample(currentPriority: Int32, basePriority: Int32) -> ThreadSample {
        ThreadSample(
            index: 0,
            identifier: 1,
            name: "",
            runState: "running",
            isIdle: false,
            isMain: false,
            cpuUsageRatio: 0,
            userNanoseconds: 0,
            systemNanoseconds: 0,
            currentPriority: currentPriority,
            basePriority: basePriority
        )
    }
}

struct ThreadInventoryReadingTests {
    @Test func anEmptyListIsReportedRatherThanLeftSilent() {
        var out = readings()
        ThreadInventoryReading.write([], into: &out)

        #expect(out.componentsWritten == [.mechanismStatus])
    }

    /// The count rides every row, so a reader that takes one entity still learns
    /// how many threads there were.
    @Test func everyRowCarriesHowManyThreadsThereWere() {
        var out = readings()
        ThreadInventoryReading.write(
            [named("main"), named("worker"), named("io")],
            into: &out
        )

        #expect(out.sealedSiblings().count == 2)
        #expect(rendered(out.sealed(), .occurrenceCount) == "3")
        #expect(rendered(out.sealedSiblings()[0], .occurrenceCount) == "3")
    }

    @Test func anUnnamedThreadOmitsTheNameRatherThanSendingAnEmptyOne() {
        var out = readings()
        ThreadInventoryReading.write([named("")], into: &out)

        #expect(out.componentsWritten.contains(.threadName) == false)
    }

    private func named(_ name: String) -> ThreadSample {
        ThreadSample(
            index: 0,
            identifier: UInt64(abs(name.hashValue)) + 1,
            name: name,
            runState: "running",
            isIdle: false,
            isMain: name == "main",
            cpuUsageRatio: 0.1,
            userNanoseconds: 100,
            systemNanoseconds: 50,
            currentPriority: 31,
            basePriority: 31
        )
    }

    private func readings() -> Readings {
        Readings(
            entity: .thread,
            instrumentName: "concurrency.thread.inventory"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}

struct ProcessWakeupsTests {
    /// A freshly started process has woken nobody, so the fact worth asserting
    /// is that the counter tracks wakes rather than that it is non-zero. Twenty
    /// sleeps are twenty timer wakes, and a field read at the wrong offset does
    /// not follow them.
    @Test func interruptsClimbWithTheWakesThatCauseThem() throws {
        let before = try #require(ProcessWakeups.read())
        for _ in 0 ..< 20 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let after = try #require(ProcessWakeups.read())

        #expect(after.interrupts > before.interrupts)
    }

    /// Both counters only ever climb. A decrease would mean the fields are being
    /// read at the wrong offsets, and every rate built on them would be a huge
    /// number arriving out of nowhere.
    @Test func neitherCounterEverFalls() throws {
        let before = try #require(ProcessWakeups.read())
        Thread.sleep(forTimeInterval: 0.05)
        let after = try #require(ProcessWakeups.read())

        #expect(after.interrupts >= before.interrupts)
        #expect(after.platformIdle >= before.platformIdle)
    }
}
