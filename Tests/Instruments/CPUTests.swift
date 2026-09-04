@testable import Basset
import BassetEntityComponent
import Testing

struct ThreadCPUUsageConfigTests {
    @Test func aZeroWindowIsClampedToOneSecond() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 0))
        #expect(instrument.windowSeconds == 1)
    }

    @Test func aHugeWindowIsClampedToThirtySeconds() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: .max))
        #expect(instrument.windowSeconds == 30)
    }

    @Test func anOrdinaryWindowPassesThroughUnchanged() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))
        #expect(instrument.windowSeconds == 5)
    }

    /// The clamp and the schema a caller reads before it must never quietly disagree.
    @Test func theClampMatchesItsOwnDeclaredMetadataRange() throws {
        let field = try #require(
            InstrumentID.cpuThreadUsage.metadata.config.first { $0.key == "windowSeconds" }
        )
        let range = try #require(field.type.intRange)

        let lowest = ThreadCPUUsage(config: .init(windowSeconds: .min))
        let highest = ThreadCPUUsage(config: .init(windowSeconds: .max))
        #expect(lowest.windowSeconds == range.lowerBound)
        #expect(highest.windowSeconds == range.upperBound)
    }
}

struct ThreadCPUUsageWindowTests {
    private let window: UInt64 = 5000000000

    @Test func theProcessTotalLeadsAndSumsEveryThread() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))
        let elapsed = Context.FlushWindow(nanoseconds: window)
        var seeding = Readings(.process)
        instrument.write(
            snapshot([sample(1, cpu: 100), sample(2, cpu: 100)]),
            over: elapsed,
            into: &seeding
        )

        var out = Readings(.process)
        instrument.write(
            snapshot([sample(1, cpu: 3000000100), sample(2, cpu: 4000000100)]),
            over: elapsed,
            into: &out
        )
        let process = out.build()
        let threads = out.additionalEntities()

        #expect(process.known == .process)
        #expect(process.components
            .first { $0.known == .cpuNanoseconds }?
            .value
            .rendered == "7000000000")
        #expect(process.components.first { $0.known == .cpuUsageRatio }?.value.rendered == "1.4")
        #expect(threads.count == 2)
        #expect(threads.allSatisfy { $0.known == .thread })
        #expect(threads[0]
            .components
            .first { $0.known == .cpuNanoseconds }?
            .value
            .rendered == "4000000000")
    }

    @Test func anIdleWindowStillWritesAZeroProcessTotal() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))
        let elapsed = Context.FlushWindow(nanoseconds: window)
        var seeding = Readings(.process)
        instrument.write(snapshot([sample(1, cpu: 100)]), over: elapsed, into: &seeding)

        var out = Readings(.process)
        instrument.write(snapshot([sample(1, cpu: 100)]), over: elapsed, into: &out)

        #expect(out.build().components.first { $0.known == .cpuNanoseconds }?.value.rendered == "0")
        #expect(out.additionalEntities().isEmpty)
    }

    @Test func aThreadBornAndGoneWithinOneWindowIsStillReported() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))

        let seeding = instrument.consumed(in: snapshot([sample(1, cpu: 900)]), within: window)
        #expect(seeding.isEmpty, "the first window has nothing to measure against")

        let burned = instrument.consumed(
            in: snapshot([sample(1, cpu: 900), sample(2, cpu: 4000000)]),
            within: window
        )
        #expect(
            burned.contains { $0.sample.identifier == 2 },
            "a thread that appeared and burned a core inside one window was dropped"
        )
    }

    @Test func aThreadMissingFromARefusedWindowIsNotCountedAsBornInTheNext() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))

        _ = instrument.consumed(in: snapshot([sample(1, cpu: 10)]), within: window)
        _ = instrument.consumed(
            in: snapshot([sample(1, cpu: 20)], complete: false),
            within: window
        )

        let after = instrument.consumed(
            in: snapshot([sample(1, cpu: 30), sample(2, cpu: 600000000000)]),
            within: window
        )
        #expect(
            !after.contains { $0.sample.identifier == 2 },
            "a thread the kernel refused once was reported as burning its whole life"
        )
    }

    @Test func aNewThreadIsNeverCreditedWithMoreThanItsWindow() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))

        _ = instrument.consumed(in: snapshot([sample(1, cpu: 10)]), within: window)
        let after = instrument.consumed(
            in: snapshot([sample(1, cpu: 20), sample(2, cpu: window * 100)]),
            within: window
        )

        #expect(after.first { $0.sample.identifier == 2 }?.nanoseconds == window)
    }

    private func snapshot(
        _ samples: [ThreadSample],
        complete: Bool = true
    ) -> ThreadInventory.Snapshot {
        ThreadInventory.Snapshot(samples: samples, isComplete: complete)
    }

    private func sample(_ identifier: UInt64, cpu: UInt64) -> ThreadSample {
        ThreadSample(
            index: Int(identifier),
            identifier: identifier,
            name: "basset.busy.\(identifier)",
            runState: "running",
            isIdle: false,
            requestedQos: "userInitiated",
            isMain: false,
            cpuUsageRatio: 1,
            userNanoseconds: cpu,
            systemNanoseconds: 0,
            currentPriority: 31,
            basePriority: 31
        )
    }
}
