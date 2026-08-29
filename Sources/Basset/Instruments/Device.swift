import BassetEntityComponent
import Foundation

final class DeviceInfo: Snapshotable, PlainInstrument {
    static let id: InstrumentID = .deviceInfo

    init() {}

    func reading() -> Readings {
        var out = Readings(.device)
        let identity = DeviceIdentity.current()
        // The same string a request targets on, not the hw.model board id (e.g. D93AP).
        out.put(.deviceModel(identity.model))
        out.put(.osVersion(ProcessInfo.processInfo.operatingSystemVersionString))
        out.put(.appVersion(identity.appVersion))
        out.put(.buildConfiguration(identity.buildConfiguration))
        out.put(.deviceKind(identity.deviceKind))
        out.put(.sdkVersion(SDKVersion.current))
        out.put(.bootTimeMicroseconds(SystemBoot.microseconds))
        out.put(.debuggerAttached(Debugger.isAttached))
        if let bundleId = identity.bundleId {
            out.put(.bundleId(bundleId))
        }
        // Both needed: version alone can't distinguish builds, and load address slides per launch.
        if let executable = BinaryImages.mainExecutable() {
            out.put(.buildUUID(executable.uuid))
            out.put(.imageLoadAddress(executable.loadAddress))
        }
        return out
    }
}
