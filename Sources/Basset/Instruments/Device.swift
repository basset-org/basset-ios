import BassetECS
import Foundation

final class DeviceInfo: SnapshotInstrument {
    static let id: InstrumentID = .deviceInfo
    static let entity = Entity.ID.device

    init() {}

    func reading(_ out: inout Readings) {
        let identity = DeviceIdentity.current()
        // The same string the device upserts and a request targets on. Reading
        // the hardware a second time here answered `hw.model` — a board id like
        // D93AP — so the capture named a device that no `--model` could select.
        out.put(.deviceModel(identity.model))
        out.put(.osVersion(ProcessInfo.processInfo.operatingSystemVersionString))
        out.put(.appVersion(identity.appVersion))
        out.put(.buildConfiguration(identity.buildConfiguration))
        out.put(.deviceKind(identity.deviceKind))
        if let bundleId = identity.bundleId {
            out.put(.bundleId(bundleId))
        }
        // Which build, and where this launch put it. The version string cannot
        // tell two builds apart and address space slides every launch, so a
        // reading carrying one without the other symbolicates nothing.
        if let executable = BinaryImages.mainExecutable() {
            out.put(.buildUUID(executable.uuid))
            out.put(.imageLoadAddress(executable.loadAddress))
        }
    }
}
