import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A permission that moved while the app was running, and nothing else.
///
/// **No framework here posts a change notification**, so this is a poll and says
/// so. It re-reads when the app comes back to the front, which is the first
/// moment a trip to Settings can have happened; the timestamp on a row is when
/// basset *noticed*, not when the user tapped.
///
/// The honest limit that goes with it: iOS terminates the app for most privacy
/// changes made in Settings, so the common case is not a delta at all but a
/// relaunch, and it is `permissions.status` under an `at_launch` request that
/// catches those. What survives to be seen here is the rest — a limited photo
/// selection changed, a toggle that does not force a restart, a prompt answered
/// by a sheet the app itself raised.
final class PermissionChanges: StreamingInstrument {
    static let id: InstrumentWireID = .permissionChanges
    static let entity = Entity.WireID.permission

    private let lock: NSLock = .init()
    private var lastSeen: [String: String] = [:]
    private var observer: NSObjectProtocol?

    init() {}

    func observe(_ context: Context) {
        // The baseline, without which a later row says a status changed to
        // something and never says what from.
        emit(PermissionProbe.findings(), into: context)

        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.emit(self.moved(in: PermissionProbe.findings()), into: context)
        }
        #endif
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        lock.withLock { lastSeen.removeAll() }
    }

    /// A subject with no status never moves — HealthKit's is unknowable by
    /// design, and reporting it as a change on every foreground would be the
    /// mechanism talking rather than the device.
    private func moved(in findings: [PermissionFinding]) -> [PermissionFinding] {
        lock.withLock {
            findings.filter { finding in
                guard let status = finding.status else {
                    return false
                }

                return lastSeen[finding.subject] != status
            }
        }
    }

    private func emit(_ findings: [PermissionFinding], into context: Context) {
        guard !findings.isEmpty else {
            return
        }

        lock.withLock {
            for finding in findings {
                guard let status = finding.status else {
                    continue
                }

                lastSeen[finding.subject] = status
            }
        }
        context.emit { out in
            PermissionStatus.write(findings, into: &out)
        }
    }
}
