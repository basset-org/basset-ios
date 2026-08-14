import BassetECS
import Foundation

#if os(iOS)
import AVFoundation
import CoreMedia
import ObjectiveC
#endif

final class CameraDeviceFormat: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentID = .cameraDeviceFormat
    static let entity = Entity.ID.captureDevice

    private let observations: Observations = .init()

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

            self.observations.attach {
                [
                    Observation.attach(to: session, keyPath: "running") { [weak self] _ in
                        self?.report(session, instance: instance, into: context)
                    },
                ]
            }
        }
        #endif
    }

    func stopObserving() {
        observations.detachAll()
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

                // Whether frames flow: requested pixel format vs. what the active format supports.
                // `videoSettings` is nil when the app asked for the device-native format.
                if let requested = path.output.videoSettings?[
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

final class CameraDeviceInventory: StreamingInstrument {
    static let id: InstrumentID = .cameraDeviceInventory
    static let entity = Entity.ID.captureDevice

    #if os(iOS)
    /// Named, not from `allCases` (AVFoundation has none) — a later type is absent from any list.
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

        // Which pairs the hardware can actually run at once — changes between phones.
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

final class CameraFrameDelivery: StreamingInstrument, LoadTimeInstall {
    private struct State {
        var instrumented: Set<ObjectIdentifier> = []
        /// Delegate classes this defined a callback on; every output on one needs rebinding.
        var defined: Set<ObjectIdentifier> = []
        var rebinding: Set<ObjectIdentifier> = []
        var watching = 0
    }

    static let id: InstrumentID = .cameraFrameDelivery
    static let entity = Entity.ID.videoFrames

    private static let delivered: TallySlot = .first
    private static let dropped: TallySlot = .second
    private static let reason: TallySlot = .third

    #if os(iOS)
    private static let didOutput: Selector = .init(
        "captureOutput:didOutputSampleBuffer:fromConnection:"
    )
    private static let didDrop: Selector = .init(
        "captureOutput:didDropSampleBuffer:fromConnection:"
    )
    #endif

    private let guarded: Mutex<State> = .init(State())

    private var isWatchingSomething: Bool {
        guarded.withLock { $0.watching > 0 }
    }

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        // Catches the delegate assignment — `addOutput` says nothing about an existing one.
        hooks.catchChanges(
            of: AVCaptureVideoDataOutput.self,
            atCallTakingTwo: #selector(
                AVCaptureVideoDataOutput.setSampleBufferDelegate(_:queue:)
            ),
            on: AVCaptureVideoDataOutput.self
        )
        hooks.catchBirths(
            of: AVCaptureVideoDataOutput.self,
            at: #selector(AVCaptureSession.addOutput(_:)),
            on: AVCaptureSession.self
        )
        #endif
    }

    func observe(_ context: Context) {
        #if os(iOS)
        context.follow(AVCaptureVideoDataOutput.self) { [weak self] output, _ in
            self?.instrument(output, with: context)
        }

        // Emitted every interval, even empty — silence and a starved camera read the same.
        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self, self.isWatchingSomething else {
                return
            }

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.framesDeliveredCount(context.tally.take(Self.delivered)))
            out.put(.framesDroppedCount(context.tally.take(Self.dropped)))
            let weight = context.tally.take(Self.reason)
            if weight > 0 {
                out.put(.dropReason(Self.named(weight)))
            }
        }
        #endif
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
    }

    #if os(iOS)
    private func instrument(_ output: AVCaptureVideoDataOutput, with context: Context) {
        guard let delegate = output.sampleBufferDelegate,
              let subject = object_getClass(delegate)
        else {
            return
        }

        // Per delegate class, not output — rewrites a class method; shared types double-count.
        let fresh = guarded.withLock { state -> Bool in
            let fresh = state.instrumented.insert(ObjectIdentifier(subject)).inserted
            if fresh {
                state.watching += 1
            }

            return fresh
        }
        guard fresh else {
            // Class already hooked, but this output wasn't bound when the callback was defined.
            rebindIfDefined(output, delegate: delegate, subject: subject)
            return
        }

        let hot = context.hotPath
        let delivery = context.swizzle
            .sampleBufferCallback(subject, Self.didOutput) { _, _, _, _ in
                guard hot.isActive else {
                    return
                }

                hot.add(Self.delivered)
            }
        let drop = context.swizzle
            .sampleBufferCallback(subject, Self.didDrop) { _, _, buffer, _ in
                guard hot.isActive else {
                    return
                }

                hot.add(Self.dropped)
                hot.raise(Self.reason, to: Self.weigh(buffer))
            }

        // Either callback — a delegate defining only `didDrop` left delivered frames at zero.
        guard delivery == .implemented || drop == .implemented else {
            return
        }

        guarded.withLock { $0.defined.insert(ObjectIdentifier(subject)) }
        rebind(output, delegate: delegate)
    }

    private func rebindIfDefined(
        _ output: AVCaptureVideoDataOutput,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        subject: AnyClass
    ) {
        let wasDefined = guarded.withLock { $0.defined.contains(ObjectIdentifier(subject)) }
        guard wasDefined else {
            return
        }

        rebind(output, delegate: delegate)
    }

    /// Re-setting the delegate re-enters this setter — guarded per output, not per class.
    private func rebind(
        _ output: AVCaptureVideoDataOutput,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) {
        guard let queue = output.sampleBufferCallbackQueue else {
            return
        }

        let key = ObjectIdentifier(output)
        let alreadyRebinding = guarded.withLock { !$0.rebinding.insert(key).inserted }
        guard !alreadyRebinding else {
            return
        }

        output.setSampleBufferDelegate(delegate, queue: queue)

        guarded.withLock { $0.rebinding.remove(key) }
    }

    /// Highest weight wins the interval, so the reason explaining a stall survives over the rest.
    private static func weigh(_ buffer: UnsafeRawPointer?) -> UInt64 {
        guard let buffer else {
            return 0
        }

        let sample = Unmanaged<CMSampleBuffer>.fromOpaque(buffer).takeUnretainedValue()
        guard let reason = CMGetAttachment(
            sample,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) as? String else {
            return 0
        }

        let discontinuity = kCMSampleBufferDroppedFrameReason_Discontinuity as String
        let late = kCMSampleBufferDroppedFrameReason_FrameWasLate as String
        let outOfBuffers = kCMSampleBufferDroppedFrameReason_OutOfBuffers as String

        if reason == outOfBuffers {
            return 3
        }
        if reason == late {
            return 2
        }
        if reason == discontinuity {
            return 1
        }
        return 0
    }

    private static func named(_ weight: UInt64) -> String {
        switch weight {
        case 1: "Discontinuity"
        case 2: "FrameWasLate"
        case 3: "OutOfBuffers"
        default: "unknown"
        }
    }
    #endif
}

final class CameraSessionConfiguration: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentID = .cameraSessionConfiguration
    static let entity = Entity.ID.captureSession

    private let observations: Observations = .init()

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

            // Emitted at attach and on every start/stop — a config that never runs still matters.
            self.observations.attach {
                [
                    Observation.attach(to: session, keyPath: "running") { [weak self] _ in
                        self?.report(session, instance: instance, into: context)
                    },
                ]
            }
        }
        #endif
    }

    func stopObserving() {
        observations.detachAll()
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

            // Multi-cam only: the number a session refuses to start, configured but not running.
            if let multiCam = session as? AVCaptureMultiCamSession {
                out.put(.hardwareCostRatio(multiCam.hardwareCost))
                out.put(.systemPressureCostRatio(multiCam.systemPressureCost))
            }
        }
    }
    #endif
}

final class CameraSessionState: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentID = .cameraSessionState
    static let entity = Entity.ID.captureSession

    private static let observed = ["running", "interrupted"]

    private let observations: Observations = .init()

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

            // One reading per change, one at attach — not per key path, or the value doubles up.
            self.observations.attach {
                Self.observed.map { keyPath in
                    Observation.attach(
                        to: session,
                        keyPath: keyPath,
                        initial: keyPath == Self.observed.first
                    ) { [weak self] _ in
                        self?.report(session, instance: instance, into: context)
                    }
                }
            }
        }
        #endif
    }

    func stopObserving() {
        observations.detachAll()
    }

    #if os(iOS)
    /// Session identity alongside state — an app with a preview and a capture session has two.
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
