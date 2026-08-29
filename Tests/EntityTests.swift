@testable import Basset
import BassetEntityComponent
import Testing

struct EntityTests {
    @Test func buildsDeviceEntity() {
        let device = Entity(.device, components: [.deviceModel("iPhone17,2"), .fps(59.9)])

        #expect(device.id == .device)
        #expect(device.components == [.deviceModel("iPhone17,2"), .fps(59.9)])
    }

    @Test func componentsKeepTheOrderTheyWereAddedIn() {
        let call = Entity(
            .methodCall,
            components: [.methodName("load"), .methodDurationMilliseconds(12.5)]
        )

        #expect(call.components.map(\.value) == [.string("load"), .float32(12.5)])
    }

    @Test func descriptionNamesEachComponent() {
        let device = Entity(.device, components: [.fps(60), .deviceModel("iPhone17,2")])

        #expect(device.description == "device:\n  fps: 60.0\n  deviceModel: iPhone17,2")
    }
}
