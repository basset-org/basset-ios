import Basset
import BassetEntityComponent

var call: Entity = .init(.methodCall)
call.add(.methodName("AVFoundation.AVCaptureSession.addInput"))
call.add(.source("AVFoundation"))
call.add(.methodDurationMilliseconds(1111.11))
print(call)
print("")

var device: Entity = .init(.device)
device.add(.deviceModel("iPhone17,2"))
device.add(.osVersion("26.0"))
device.add(.cpuUsageRatio(0.29))
device.add(.fps(59.9))
print(device)
print("")

var version: Entity = .init(.serverVersion)
version.add(.appVersion("4.2.0"))
version.add(.serverVersion("2026.28.1"))
print(version)
