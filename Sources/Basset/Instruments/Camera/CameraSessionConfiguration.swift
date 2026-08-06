import BassetECS
import Foundation
#if os(iOS)
import AVFoundation
#endif

final class CameraSessionConfiguration: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .cameraSessionConfiguration
    static let entity = Entity.WireID.captureSession

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

            self.observations.removeAll { !$0.isAttached }
            // Once when the session is caught, and again whenever it starts
            // or stops. A configuration that never reaches running is the
            // reading worth having, so it is emitted before anything runs
            // rather than only alongside a state change.
            self.observations.append(
                Observation.attach(to: session, keyPath: "running") { [weak self] _ in
                    self?.report(session, instance: instance, into: context)
                }
            )
        }
        #endif
    }

    func stopObserving() {
        observations.forEach { $0.detach() }
        observations.removeAll()
    }

    #if os(iOS)
    private func report(
        _ session: AVCaptureSession,
        instance: UInt32,
        into context: Context
    ) {
        let connections = session.connections
        let carrying = connections.filter { $0.isActive && $0.isEnabled }

        context.emit { out in
            out.put(.instanceId(instance))
            out.put(.sessionClass(String(describing: type(of: session))))
            out.put(.sessionPreset(session.sessionPreset.rawValue))
            out.put(.inputCount(UInt32(session.inputs.count)))
            out.put(.outputCount(UInt32(session.outputs.count)))
            out.put(.connectionCount(UInt32(connections.count)))
            out.put(.activeConnectionCount(UInt32(carrying.count)))
            out.put(.sessionRunning(session.isRunning))

            // Multi-camera only, and the number a session refuses to start
            // over. A caller that gates its own start on this and gives up
            // leaves a session that is configured, not running, and silent.
            if let multiCam = session as? AVCaptureMultiCamSession {
                out.put(.hardwareCostRatio(multiCam.hardwareCost))
                out.put(.systemPressureCostRatio(multiCam.systemPressureCost))
            }
        }
    }
    #endif
}
