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
