@testable import Basset
import BassetECS
import Testing

struct DeviceInfoTests {
    @Test func theReadingCarriesThisSDKsOwnVersion() {
        var out = Readings(entity: DeviceInfo.entity, instrumentName: DeviceInfo.name)
        DeviceInfo().reading(&out)

        let version = out.sealed().components.first { $0.id == .sdkVersion }?.value.rendered
        #expect(version == SDKVersion.current)
    }
}
