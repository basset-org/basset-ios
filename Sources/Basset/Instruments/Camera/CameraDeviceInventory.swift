import BassetECS
import Foundation
#if os(iOS)
import AVFoundation
#endif

final class CameraDeviceInventory: StreamingInstrument {
    static let id: InstrumentWireID = .cameraDeviceInventory
    static let entity = Entity.WireID.captureDevice

    #if os(iOS)
    // Named rather than derived from `allCases`, which AVFoundation does not
    // offer: a type Apple adds with a new phone is absent from any list
    // written before it, and the set this reports is the one a caller's own
    // discovery would have missed.
    private static let probed: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera,
        .builtInDualCamera,
        .builtInDualWideCamera,
        .builtInTripleCamera,
        .builtInTrueDepthCamera,
        .builtInLiDARDepthCamera,
        .continuityCamera,
        .external,
    ]
    #endif

    init() {}

    #if os(iOS)
    private static func describe(_ set: Set<AVCaptureDevice>) -> String {
        set
            .map { "\($0.deviceType.rawValue)@\(named($0.position))" }
            .sorted()
            .joined(separator: "+")
    }

    private static func named(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: "front"
        case .back: "back"
        case .unspecified: "unspecified"
        @unknown default: "unknown"
        }
    }
    #endif

    func observe(_ context: Context) {
        #if os(iOS)
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.probed,
            mediaType: .video,
            position: .unspecified
        )

        for device in discovery.devices {
            context.emit(.captureDevice) { out in
                out.put(.deviceType(device.deviceType.rawValue))
                out.put(.devicePosition(Self.named(device.position)))
                out.put(.deviceUniqueId(device.uniqueID))
                out.put(.formatCount(UInt32(device.formats.count)))
                out.put(
                    .formatMultiCamSupported(
                        device.formats.contains { $0.isMultiCamSupported }
                    )
                )
            }
        }

        // The matrix itself, not only its members. Which pairs the hardware
        // will actually run at once is the question a caller answers by
        // asking for a set and being told no, and it changes between phones.
        for (index, set) in discovery.supportedMultiCamDeviceSets.enumerated() {
            context.emit(.multiCamSet) { out in
                out.put(.multiCamSetIndex(UInt32(index)))
                out.put(.multiCamSetMembers(Self.describe(set)))
            }
        }
        #endif
    }

    func stopObserving() {}
}
