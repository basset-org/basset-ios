@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

/// A plain `Bool` behind `@unchecked Sendable` compiles but is a data race the sanitizer catches.
private final class Released: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<UInt8> = .allocate(capacity: 1)

    var value: Bool {
        get { Atomics.loadRelaxed(slot) != 0 }
        set { Atomics.storeReleasing(slot, newValue ? 1 : 0) }
    }

    init() {
        Atomics.initialize(slot, 0)
    }

    deinit {
        slot.deallocate()
    }
}

/// Serialized: these hold threads against the scheduler and contend for cores with timing suites.
@Suite(.serialized)
struct ThreadInventoryReadTests {
    /// Every process has a main thread, so an empty answer is a broken read, not a quiet one.
    @Test func theProcessDescribesItsOwnThreads() {
        let samples = ThreadInventory.read()

        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.identifier != 0 })
        #expect(samples.allSatisfy { !$0.runState.hasPrefix("unrecognised") })
    }

    /// Ids must be stable — everything that computes a rate pairs reads on them.
    @Test func threadIdentifiersAreStableBetweenReads() {
        let first = ThreadInventory.read()
        let second = ThreadInventory.read()

        let shared = Set(first.map(\.identifier)).intersection(second.map(\.identifier))
        #expect(!shared.isEmpty)
    }

    /// A total going backwards means the field is read at the wrong offset — confident nonsense.
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

    /// `userInitiated`, not `background` — may not start at all on a shared simulator.
    @Test func aThreadsRequestedClassAndPriorityAreReadFromOutside() async {
        let done = DispatchGroup()
        let release = Released()

        done.enter()
        let resting = Thread {
            "basset.resting.probe".withCString { _ = pthread_setname_np($0) }
            while !release.value {
                Thread.sleep(forTimeInterval: 0.02)
            }
            done.leave()
        }
        resting.qualityOfService = .userInitiated
        resting.start()

        defer {
            release.value = true
            #expect(done.wait(timeout: .now() + TestMachine.joinTimeout) == .success)
        }

        let named = await eventually {
            ThreadInventory.read().contains { $0.name == "basset.resting.probe" }
        }
        #expect(named, "a named background thread was never inventoried")

        let sample = ThreadInventory.read().first { $0.name == "basset.resting.probe" }
        #expect(sample?.requestedQos == "userInitiated")
        #expect((sample?.currentPriority ?? -1) >= 0, "no priority was read for it")
    }

    /// Skipped on a shared simulator — the inversion needs spare cores, else it reports the load.
    @Test(.enabled(if: !TestMachine.isSharedSimulator))
    func aDonatedThreadIsReadAsBoostedFromOutside() {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())

        // Every thread touching the lock is joined before it is freed, or the process aborts.
        let done = DispatchGroup()
        defer {
            // A join that doesn't finish leaks the allocation rather than free it under a waiter.
            if done.wait(timeout: .now() + TestMachine.joinTimeout) == .success {
                lock.deallocate()
            } else {
                Issue.record("a thread was still blocked on the lock")
            }
        }

        let holding = DispatchSemaphore(value: 0)
        done.enter()
        let holder = Thread {
            "basset.donation.holder".withCString { _ = pthread_setname_np($0) }
            os_unfair_lock_lock(lock)
            holding.signal()
            Thread.sleep(forTimeInterval: 2)
            os_unfair_lock_unlock(lock)
            done.leave()
        }
        holder.qualityOfService = .background
        holder.start()
        holding.wait()

        let resting = holderSample()
        #expect(resting?.requestedQos == "background")
        let restingAt = resting?.currentPriority ?? -1

        for index in 0 ..< 4 {
            done.enter()
            let waiter = Thread {
                "basset.donation.waiter.\(index)"
                    .withCString { _ = pthread_setname_np($0) }
                os_unfair_lock_lock(lock)
                os_unfair_lock_unlock(lock)
                done.leave()
            }
            waiter.qualityOfService = .userInteractive
            waiter.start()
        }
        // Polled rather than slept fixed — a loaded machine would otherwise fail a healthy build.
        var donated = holderSample()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (donated?.currentPriority ?? restingAt) <= restingAt {
            Thread.sleep(forTimeInterval: 0.05)
            donated = holderSample()
        }

        #expect(
            donated?.requestedQos == "background",
            "donation moved the class the thread asked for, so nothing can be compared"
        )
        #expect(
            (donated?.currentPriority ?? restingAt) > restingAt,
            "a blocked-on background holder stayed at priority \(restingAt)"
        )
    }

    /// `TH_FLAGS_IDLE` marks kernel idle threads, never an app's — idle comes from behavior.
    @Test func aParkedThreadIsIdleAndABusyOneIsNot() async {
        // The busy probe spins on a plain flag — a semaphore's syscall costs more than it takes.
        let done = DispatchGroup()
        let release = Released()

        done.enter()
        let parked = Thread {
            "basset.parked.probe".withCString { _ = pthread_setname_np($0) }
            while !release.value {
                Thread.sleep(forTimeInterval: 0.02)
            }
            done.leave()
        }
        parked.start()

        done.enter()
        let spinning = Thread {
            "basset.spinning.probe".withCString { _ = pthread_setname_np($0) }
            while !release.value {}
            done.leave()
        }
        spinning.start()

        defer {
            release.value = true
            #expect(done.wait(timeout: .now() + TestMachine.joinTimeout) == .success)
        }

        let bothStarted = await eventually {
            let named = Set(ThreadInventory.read().compactMap(\.name))
            return named.contains("basset.parked.probe")
                && named.contains("basset.spinning.probe")
        }
        #expect(bothStarted, "a probe thread was never scheduled at all")

        let sawParkedThreadAsleep = await eventually {
            ThreadInventory.read()
                .first { $0.name == "basset.parked.probe" }?
                .isIdle == true
        }
        #expect(sawParkedThreadAsleep, "a sleeping thread was never reported idle")

        let spinningThread = ThreadInventory.read()
            .first { $0.name == "basset.spinning.probe" }
        #expect(spinningThread != nil, "the spinning probe left the inventory")
        #expect(
            spinningThread?.isIdle == false,
            "a thread burning a core was reported idle"
        )
    }

    private func holderSample() -> ThreadSample? {
        ThreadInventory.read().first { $0.name == "basset.donation.holder" }
    }
}

struct ThreadInventoryReadingTests {
    @Test func anEmptyListIsReportedRatherThanLeftSilent() {
        var out = readings()
        ThreadInventoryReading.write([], into: &out)

        #expect(out.componentsWritten == [.mechanismStatus])
    }

    /// The count rides every row, so a reader taking only one entity still learns the total.
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
            requestedQos: "default",
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
    /// Asserts the counter tracks wakes, not just non-zero — a fresh process has woken nobody.
    @Test func interruptsClimbWithTheWakesThatCauseThem() throws {
        let before = try #require(ProcessWakeups.read())
        for _ in 0 ..< 20 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let after = try #require(ProcessWakeups.read())

        #expect(after.interrupts > before.interrupts)
    }

    /// A decrease would mean the fields are read at the wrong offsets.
    @Test func neitherCounterEverFalls() throws {
        let before = try #require(ProcessWakeups.read())
        Thread.sleep(forTimeInterval: 0.05)
        let after = try #require(ProcessWakeups.read())

        #expect(after.interrupts >= before.interrupts)
        #expect(after.platformIdle >= before.platformIdle)
    }
}
