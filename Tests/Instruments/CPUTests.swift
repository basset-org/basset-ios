@testable import Basset
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
}
