import BassetECS
import Foundation
#if os(iOS)
import AVFoundation
import CoreMedia
#endif

final class CameraDeviceFormat: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .cameraDeviceFormat
    static let entity = Entity.WireID.captureDevice

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
        for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) {
            let device = input.device
            let format = device.activeFormat
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            let rates = format.videoSupportedFrameRateRanges
            let path = Self.videoPath(for: input, in: session)

            context.emitIfChanged(.captureDevice, of: device.uniqueID) { out in
                out.put(.instanceId(instance))
                out.put(.deviceType(device.deviceType.rawValue))
                out.put(.devicePosition(Self.named(device.position)))
                out.put(.deviceUniqueId(device.uniqueID))
                out.put(.formatWidthPixels(dimensions.width))
                out.put(.formatHeightPixels(dimensions.height))
                out.put(
                    .formatPixelFormat(
                        Self.fourCharacterCode(
                            CMFormatDescriptionGetMediaSubType(format.formatDescription)
                        )
                    )
                )
                out
                    .put(.formatMinFramesPerSecond(Float(rates.map(\.minFrameRate)
                            .min() ?? 0)))
                out
                    .put(.formatMaxFramesPerSecond(Float(rates.map(\.maxFrameRate)
                            .max() ?? 0)))
                out.put(.formatMultiCamSupported(format.isMultiCamSupported))
                out.put(.formatCount(UInt32(device.formats.count)))
                out.put(.activeColorSpace(Self.named(device.activeColorSpace)))
                out.put(.systemPressureLevel(device.systemPressureState.level.rawValue))

                guard let path else {
                    return
                }

                // The join that decides whether frames can flow at all: a
                // pixel format the output was told to hand over, against the
                // ones the format now active is able to give it. The two are
                // set at different moments and nothing reconciles them.
                if let requested = path.output.videoSettings[
                    kCVPixelBufferPixelFormatTypeKey as String
                ] as? UInt32 {
                    out.put(.outputPixelFormat(Self.fourCharacterCode(requested)))
                    out.put(
                        .outputPixelFormatSupported(
                            path.output
                                .availableVideoPixelFormatTypes
                                .contains(OSType(requested))
                        )
                    )
                }
                out.put(.videoRotationDegrees(Float(path.connection.videoRotationAngle)))
                out.put(.videoMirrored(path.connection.isVideoMirrored))
            }
        }
    }

    private static func videoPath(
        for input: AVCaptureDeviceInput,
        in session: AVCaptureSession
    ) -> (output: AVCaptureVideoDataOutput, connection: AVCaptureConnection)? {
        for output in session.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }) {
            guard let connection = output.connection(with: .video) else {
                continue
            }

            let feeds = connection.inputPorts.contains { port in
                (port.input as? AVCaptureDeviceInput) === input
            }
            if feeds {
                return (output, connection)
            }
        }
        return nil
    }

    private static func fourCharacterCode(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7f }
        guard printable else {
            return "0x\(String(code, radix: 16))"
        }

        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    private static func named(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: "front"
        case .back: "back"
        case .unspecified: "unspecified"
        @unknown default: "unknown"
        }
    }

    private static func named(_ space: AVCaptureColorSpace) -> String {
        switch space {
        case .sRGB: "sRGB"
        case .P3_D65: "P3_D65"
        case .HLG_BT2020: "HLG_BT2020"
        case .appleLog: "appleLog"
        @unknown default: "unknown"
        }
    }
    #endif
}
