@testable import Basset
import Foundation
import Testing

struct BinaryImagesTests {
    @Test func anAddressIsPlacedInTheImageHoldingIt() throws {
        let executable = try #require(BinaryImages.mainExecutable())
        let covering = BinaryImages.covering([executable.loadAddress])

        #expect(covering.contains { $0.uuid == executable.uuid })
    }

    @Test func anAddressInNoImageIsPlacedInNone() {
        #expect(BinaryImages.covering([1]).isEmpty)
    }

    /// Reading every mapped image costs ~87µs over 347 of them, so the set is held between
    /// calls. A second answer that differs from the first would mean the hold went stale.
    @Test func repeatedLookupsAnswerTheSame() throws {
        let executable = try #require(BinaryImages.mainExecutable())
        let first = BinaryImages.covering([executable.loadAddress])
        let second = BinaryImages.covering([executable.loadAddress])

        #expect(first.map(\.uuid) == second.map(\.uuid))
        #expect(first.map(\.loadAddress) == second.map(\.loadAddress))
    }
}
