import Basset
import BassetEntityComponent

let call: Entity = .init(.methodCall, components: [
    .methodName("AVFoundation.AVCaptureSession.addInput"),
    .source("AVFoundation"),
    .methodDurationMilliseconds(1111.11),
])
print(call)
print("")

let device: Entity = .init(.device, components: [
    .deviceModel("iPhone17,2"),
    .osVersion("26.0"),
    .cpuUsageRatio(0.29),
    .fps(59.9),
])
print(device)
print("")

let version: Entity = .init(.serverVersion, components: [
    .appVersion("4.2.0"),
    .serverVersion("2026.28.1"),
])
print(version)
