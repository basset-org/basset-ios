@testable import Basset
import BassetEntityComponent
import Testing

struct DeviceInfoTests {
    @Test func theReadingCarriesThisSDKsOwnVersion() {
        var out = Readings(entity: .device, instrumentName: DeviceInfo.name)
        DeviceInfo().reading(&out)

        let version = out.sealed().components.first { $0.id == .sdkVersion }?.value.rendered
        #expect(version == SDKVersion.current)
    }
}
