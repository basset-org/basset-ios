@testable import Basset
import BassetECS
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
    @Test func aThreadBornAndGoneWithinOneWindowIsStillReported() {
        let instrument = ThreadCPUUsage(config: .init(windowSeconds: 5))

        let seeding = instrument.consumed(in: [sample(1, cpu: 900)])
        #expect(seeding.isEmpty, "the first window has nothing to measure against")

        let burned = instrument.consumed(in: [sample(1, cpu: 900), sample(2, cpu: 4000000)])
        #expect(
            burned.contains { $0.sample.identifier == 2 },
            "a thread that appeared and burned a core inside one window was dropped"
        )
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
