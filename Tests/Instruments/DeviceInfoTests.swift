@testable import Basset
import BassetEntityComponent
import Testing

struct DeviceInfoTests {
    @Test func theReadingCarriesThisSDKsOwnVersion() {
        let out = DeviceInfo().reading()

        let version = out.build().components.first { $0.known == .sdkVersion }?.value.rendered
        #expect(version == SDKVersion.current)
    }
}
