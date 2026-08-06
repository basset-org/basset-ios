@testable import Basset
import BassetECS
import Testing

struct EntityTests {
    @Test func buildsDeviceEntity() {
        var device = Entity(.device)
        device.add(.deviceModel("iPhone17,2"))
        device.add(.fps(59.9))

        #expect(device.id == .device)
        #expect(device.components == [.deviceModel("iPhone17,2"), .fps(59.9)])
    }

    @Test func componentsKeepTheOrderTheyWereAddedIn() {
        var call = Entity(.methodCall)
        call.add(.methodName("load"))
        call.add(.methodDurationMilliseconds(12.5))

        #expect(call.components.map(\.value) == [.string("load"), .float32(12.5)])
    }

    @Test func descriptionNamesEachComponent() {
        var device = Entity(.device)
        device.add(.fps(60))
        device.add(.deviceModel("iPhone17,2"))

        #expect(device.description == "device:\n  fps: 60.0\n  deviceModel: iPhone17,2")
    }
}
