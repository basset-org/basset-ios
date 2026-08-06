import BassetECS
import Foundation

/// What this user's device is actually allowing, and whether the app could even
/// ask.
///
/// A denied permission produces silence rather than an error — no callback, no
/// thrown error, no log line — so an app that cannot see the camera looks exactly
/// like an app whose camera code never ran. This is the reading that separates
/// them, and it is cheap enough to take alongside anything else.
///
/// Each row pairs the status with whether the matching `Info.plist` usage
/// description is in the build, because the two together are the diagnosis: a
/// subject sitting at `notDetermined` with no usage description is an app that
/// **terminates** the moment it asks, and no amount of reading the app's own code
/// shows that.
final class PermissionStatus: SnapshotInstrument {
    static let id: InstrumentWireID = .permissionStatus
    static let entity = Entity.WireID.permission

    init() {}

    static func write(_ findings: [PermissionFinding], into out: inout Readings) {
        guard let first = findings.first else {
            out
                .put(
                    .mechanismStatus(
                        "no permission-gated framework is linked into this app"
                    )
                )
            return
        }

        first.write(into: &out)
        for finding in findings.dropFirst() {
            out.also(Self.entity) { sibling in finding.write(into: &sibling) }
        }
    }

    func reading(_ out: inout Readings) {
        Self.write(PermissionProbe.findings(), into: &out)
    }
}
