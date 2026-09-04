@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

/// Serialized: both tests flip the one process-wide policy flag.
@Suite(.serialized)
struct ScreenshotTests {
    /// Nothing attached and no configuration opt-in: the reading says why, and carries no image.
    @Test func refusedWhenNothingIsAttachedAndTheAppDidNotOptIn() {
        ScreenshotPolicy.allowRemote(false)

        let reading = Screenshot().reading().build()

        #expect(reading.known == .screenshot)
        #expect(reading.components
            .first { $0.known == .mechanismStatus }?
            .value
            .rendered == Screenshot.refusal)
        #expect(!reading.componentIDs.contains(.imageData))
    }

    @Test func theConfigurationOptInLiftsTheRefusal() {
        ScreenshotPolicy.allowRemote(true)
        defer { ScreenshotPolicy.allowRemote(false) }

        let reading = Screenshot().reading().build()
        let status = reading.components.first { $0.known == .mechanismStatus }?.value.rendered

        #expect(status != Screenshot.refusal)
    }
}
