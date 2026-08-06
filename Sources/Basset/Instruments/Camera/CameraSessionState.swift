import BassetECS
import Foundation
#if os(iOS)
import AVFoundation
#endif

final class CameraSessionState: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .cameraSessionState
    static let entity = Entity.WireID.captureSession

    private static let observed = ["running", "interrupted"]

    private var observations: [Observation] = []

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        hooks.catchSelf(
            of: AVCaptureSession.self,
            atCallTaking: #selector(AVCaptureSession.addOutput(_:)),
            on: AVCaptureSession.self
        )
        hooks.catchSelf(
            of: AVCaptureSession.self,
            at: #selector(AVCaptureSession.startRunning),
            on: AVCaptureSession.self
        )
        #endif
    }

    func observe(_ context: Context) {
        #if os(iOS)
        context.follow(AVCaptureSession.self) { [weak self] session, instance in
            guard let self else {
                return
            }

            // Bounded by live sessions rather than by how many the app has
            // ever made: an app building one per screen visit would other-
            // wise accumulate a registration per visit for the life of the
            // request.
            self.observations.removeAll { !$0.isAttached }
            // One reading per change, and one at attach — not one per
            // observed key path. `report` writes both components whichever
            // key woke it, so asking each for its initial value emitted the
            // same reading twice and spent two of the request's readings on
            // it.
            for keyPath in Self.observed {
                self.observations.append(
                    Observation.attach(
                        to: session,
                        keyPath: keyPath,
                        initial: keyPath == Self.observed.first
                    ) { [weak self] _ in
                        self?.report(session, instance: instance, into: context)
                    }
                )
            }
        }
        #endif
    }

    func stopObserving() {
        observations.forEach { $0.detach() }
        observations.removeAll()
    }

    #if os(iOS)
    /// Which session, not just what state. Several sessions are observed at
    /// once — an app with a preview and a capture has two — and without this
    /// their readings are distinguishable only by arrival order.
    private func report(
        _ session: AVCaptureSession,
        instance: UInt32,
        into context: Context
    ) {
        context.emit { out in
            out.put(.instanceId(instance))
            out.put(.sessionRunning(session.isRunning))
            out.put(.sessionInterrupted(session.isInterrupted))
        }
    }
    #endif
}
