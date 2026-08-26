import BassetECS
import Foundation

#if os(iOS)
import CoreMedia
import CoreVideo
import ObjectiveC
#endif

final class CameraDeviceFormat: Streamable, PlainInstrument, LoadTimeInstall {
    static let id: InstrumentID = .cameraDeviceFormat
    static let entity = Entity.ID.captureDevice

    private let observations: Observations = .init()

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass else {
            return
        }

        hooks.trackSelf(
            class: session,
            atCallTaking: Selector(("addOutput:")),
            on: session
        )
        hooks.trackSelf(
            class: session,
            at: Selector(("startRunning")),
            on: session
        )
        #endif
    }

    func observe(_ context: Context) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass else {
            return
        }

        context.follow(class: session) { [weak self] session, instance in
            guard let self, let sessionObject = session as? NSObject else {
                return
            }

            self.observations.attach {
                [
                    Observation.attach(to: sessionObject, keyPath: "running") { [weak self] _ in
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
        _ session: AnyObject,
        instance: UInt32,
        into context: Context
    ) {
        guard let inputs = session.value(forKey: "inputs") as? [AnyObject],
              let deviceInputClass = objc_getClass("AVCaptureDeviceInput") as? AnyClass
        else {
            return
        }

        for input in inputs where input.isKind(of: deviceInputClass) {
            guard let device = input.value(forKey: "device") as AnyObject?,
                  let format = device.value(forKey: "activeFormat") as AnyObject?,
                  let description = Self.formatDescription(of: format)
            else {
                continue
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let rates = format.value(forKey: "videoSupportedFrameRateRanges") as? [AnyObject] ?? []
            let path = Self.videoPath(for: input, in: session)
            let uniqueID = device.value(forKey: "uniqueID") as? String ?? ""
            let position = (device.value(forKey: "position") as? NSNumber)?.intValue ?? 0
            let colorSpace = (device.value(forKey: "activeColorSpace") as? NSNumber)?.intValue ?? 0
            let level = (device.value(forKey: "systemPressureState") as AnyObject?)?
                .value(forKey: "level") as? String

            context.emitIfChanged(.captureDevice, of: uniqueID) { out in
                out.put(.instanceId(instance))
                out.put(.deviceType(device.value(forKey: "deviceType") as? String ?? ""))
                out.put(.devicePosition(Self.named(position: position)))
                out.put(.deviceUniqueId(uniqueID))
                out.put(.formatWidthPixels(dimensions.width))
                out.put(.formatHeightPixels(dimensions.height))
                out.put(
                    .formatPixelFormat(
                        Self.fourCharacterCode(CMFormatDescriptionGetMediaSubType(description))
                    )
                )
                let minRate = rates
                    .compactMap { ($0.value(forKey: "minFrameRate") as? NSNumber)?.doubleValue }
                    .min() ?? 0
                let maxRate = rates
                    .compactMap { ($0.value(forKey: "maxFrameRate") as? NSNumber)?.doubleValue }
                    .max() ?? 0
                out.put(.formatMinFramesPerSecond(Float(minRate)))
                out.put(.formatMaxFramesPerSecond(Float(maxRate)))
                out
                    .put(.formatMultiCamSupported((format
                            .value(forKey: "isMultiCamSupported") as? Bool) ?? false))
                out
                    .put(.formatCount(UInt32((device.value(forKey: "formats") as? [AnyObject])?
                            .count ?? 0)))
                out.put(.activeColorSpace(Self.named(colorSpace: colorSpace)))
                if let level {
                    out.put(.systemPressureLevel(level))
                }

                guard let path else {
                    return
                }

                // Whether frames flow: requested pixel format vs. what the active format supports.
                // `videoSettings` is nil when the app asked for the device-native format.
                if let videoSettings = path.output.value(forKey: "videoSettings") as? [String: Any],
                   let requested =
                   (videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?
                       .uint32Value
                {
                    out.put(.outputPixelFormat(Self.fourCharacterCode(requested)))
                    let available = (path.output
                        .value(forKey: "availableVideoCVPixelFormatTypes") as? [NSNumber])?
                                            .map(\.uint32Value) ?? []
                    out.put(.outputPixelFormatSupported(available.contains(requested)))
                }
                let rotation = (path.connection.value(forKey: "videoRotationAngle") as? NSNumber)?
                    .doubleValue ?? 0
                out.put(.videoRotationDegrees(Float(rotation)))
                out
                    .put(
                        .videoMirrored((
                            path.connection.value(forKey: "isVideoMirrored") as? Bool
                        ) ??
                            false)
                    )
            }
        }
    }

    private static func videoPath(
        for input: AnyObject,
        in session: AnyObject
    ) -> (output: AnyObject, connection: AnyObject)? {
        guard let outputs = session.value(forKey: "outputs") as? [AnyObject],
              let videoOutputClass = objc_getClass("AVCaptureVideoDataOutput") as? AnyClass
        else {
            return nil
        }

        for output in outputs where output.isKind(of: videoOutputClass) {
            guard let connection = Self.connection(of: output, mediaType: "vide") else {
                continue
            }

            let inputPorts = connection.value(forKey: "inputPorts") as? [AnyObject] ?? []
            let feeds = inputPorts.contains { port in
                (port.value(forKey: "input") as AnyObject?) === input
            }
            if feeds {
                return (output, connection)
            }
        }
        return nil
    }

    /// `-connectionWithMediaType:` takes one object argument — `perform(_:with:)` reaches it
    /// without importing AVFoundation for `AVMediaType.video`, execution-verified as `"vide"`.
    private static func connection(of output: AnyObject, mediaType: String) -> AnyObject? {
        output.perform(Selector(("connectionWithMediaType:")), with: mediaType as NSString)?
            .takeUnretainedValue()
    }

    /// `CMFormatDescriptionRef` is `CM_BRIDGED_TYPE(id)` — bridgeable for an ARC cast, but its
    /// raw ObjC type encoding is a C pointer, not `@`. `value(forKey: "formatDescription")`
    /// crashes on-device with "this class is not key value coding-compliant for the key
    /// formatDescription" because KVC's automatic accessor lookup refuses a non-object-encoded
    /// return type — confirmed by running the hardware suite, not by reading the header. Reached
    /// the way `PermissionProbe` reaches a class method: the raw IMP, cast to its C signature.
    private static func formatDescription(of format: AnyObject) -> CMFormatDescription? {
        let selector = Selector(("formatDescription"))
        guard let method = class_getInstanceMethod(object_getClass(format), selector) else {
            return nil
        }

        typealias Call = @convention(c) (AnyObject, Selector) -> Unmanaged<CMFormatDescription>?
        let implementation = method_getImplementation(method)
        return unsafeBitCast(implementation, to: Call.self)(format, selector)?.takeUnretainedValue()
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

    /// Raw `AVCaptureDevicePosition` values — `NS_ENUM(NSInteger, ...)`, unspecified/back/front.
    private static func named(position raw: Int) -> String {
        switch raw {
        case 1: "back"
        case 2: "front"
        default: "unspecified"
        }
    }

    /// Raw `AVCaptureColorSpace` values — `NS_ENUM(NSInteger, ...)`, sRGB through appleLog2.
    private static func named(colorSpace raw: Int) -> String {
        switch raw {
        case 0: "sRGB"
        case 1: "P3_D65"
        case 2: "HLG_BT2020"
        case 3: "appleLog"
        case 4: "appleLog2"
        default: "unknown"
        }
    }
    #endif
}

final class CameraDeviceInventory: Streamable, PlainInstrument {
    static let id: InstrumentID = .cameraDeviceInventory
    static let entity = Entity.ID.captureDevice

    #if os(iOS)
    /// Named, not from `allCases` (AVFoundation has none) — a later type is absent from any list.
    private static let probed: [String] = [
        "AVCaptureDeviceTypeBuiltInWideAngleCamera",
        "AVCaptureDeviceTypeBuiltInUltraWideCamera",
        "AVCaptureDeviceTypeBuiltInTelephotoCamera",
        "AVCaptureDeviceTypeBuiltInDualCamera",
        "AVCaptureDeviceTypeBuiltInDualWideCamera",
        "AVCaptureDeviceTypeBuiltInTripleCamera",
        "AVCaptureDeviceTypeBuiltInTrueDepthCamera",
        "AVCaptureDeviceTypeBuiltInLiDARDepthCamera",
        "AVCaptureDeviceTypeContinuityCamera",
        "AVCaptureDeviceTypeExternal",
    ]
    #endif

    init() {}

    #if os(iOS)
    private static func describe(_ set: NSSet) -> String {
        set
            .compactMap { $0 as AnyObject }
            .map { device -> String in
                let type = device.value(forKey: "deviceType") as? String ?? "unknown"
                let position = (device.value(forKey: "position") as? NSNumber)?.intValue ?? 0
                return "\(type)@\(named(position: position))"
            }
            .sorted()
            .joined(separator: "+")
    }

    private static func named(position raw: Int) -> String {
        switch raw {
        case 1: "back"
        case 2: "front"
        default: "unspecified"
        }
    }

    /// `+discoverySessionWithDeviceTypes:mediaType:position:`, a three-argument class factory —
    /// beyond `perform`'s two-argument ceiling, reached the way `PermissionProbe` calls a class
    /// method: the raw IMP, cast to its C signature.
    private static func discoverySession(
        _ discoveryClass: AnyClass,
        deviceTypes: [String],
        mediaType: String,
        position: Int
    ) -> AnyObject? {
        let selector = Selector(("discoverySessionWithDeviceTypes:mediaType:position:"))
        guard let method = class_getClassMethod(discoveryClass, selector) else {
            return nil
        }

        typealias Call = @convention(c) (AnyClass, Selector, NSArray, NSString, Int)
            -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        return unsafeBitCast(implementation, to: Call.self)(
            discoveryClass,
            selector,
            deviceTypes as NSArray,
            mediaType as NSString,
            position
        )?.takeUnretainedValue()
    }
    #endif

    func observe(_ context: Context) {
        #if os(iOS)
        guard let discoveryClass = objc_getClass("AVCaptureDeviceDiscoverySession") as? AnyClass,
              let discovery = Self.discoverySession(
                  discoveryClass,
                  deviceTypes: Self.probed,
                  mediaType: "vide",
                  position: 0
              )
        else {
            return
        }

        let devices = discovery.value(forKey: "devices") as? [AnyObject] ?? []
        for device in devices {
            let position = (device.value(forKey: "position") as? NSNumber)?.intValue ?? 0
            let formats = device.value(forKey: "formats") as? [AnyObject] ?? []

            context.emit(.captureDevice) { out in
                out.put(.deviceType(device.value(forKey: "deviceType") as? String ?? ""))
                out.put(.devicePosition(Self.named(position: position)))
                out.put(.deviceUniqueId(device.value(forKey: "uniqueID") as? String ?? ""))
                out.put(.formatCount(UInt32(formats.count)))
                out.put(
                    .formatMultiCamSupported(
                        formats
                            .contains { ($0.value(forKey: "isMultiCamSupported") as? Bool) == true }
                    )
                )
            }
        }

        // Which pairs the hardware can actually run at once — changes between phones.
        let multiCamSets = discovery.value(forKey: "supportedMultiCamDeviceSets") as? [NSSet] ?? []
        for (index, set) in multiCamSets.enumerated() {
            context.emit(.multiCamSet) { out in
                out.put(.multiCamSetIndex(UInt32(index)))
                out.put(.multiCamSetMembers(Self.describe(set)))
            }
        }
        #endif
    }

    func stopObserving() {}
}

#if os(iOS)
private func connections(of object: AnyObject) -> [AnyObject] {
    object.value(forKey: "connections") as? [AnyObject] ?? []
}

/// A connection the session has wired up and not switched off: frames should be arriving.
private func isActiveAndEnabled(_ connection: AnyObject) -> Bool {
    ((connection.value(forKey: "isActive") as? Bool) ?? false)
        && ((connection.value(forKey: "isEnabled") as? Bool) ?? false)
}
#endif

final class CameraFrameDelivery: Streamable, PlainInstrument, LoadTimeInstall {
    private struct State {
        var instrumented: Set<ObjectIdentifier> = []
        /// Delegate classes this defined a callback on; every output on one needs rebinding.
        var defined: Set<ObjectIdentifier> = []
        var rebinding: Set<ObjectIdentifier> = []
        var watching = 0
        /// Weak: an output the app released must not be kept alive to be asked about.
        let watched: NSHashTable<AnyObject> = .weakObjects()
    }

    static let id: InstrumentID = .cameraFrameDelivery
    static let entity = Entity.ID.videoFrames
    static let tallySlots = 5

    private static let delivered: TallySlot = .first
    private static let dropped: TallySlot = .second
    private static let reason: TallySlot = .third
    private static let delegateDurationTotal: TallySlot = .init(3)
    private static let delegateDurationPeak: TallySlot = .init(4)

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

    /// Zero frames while a connection is carrying is the reading this instrument exists for.
    /// Zero frames with nothing carrying is a camera that stopped, and says nothing at all.
    private var isCarrying: Bool {
        #if os(iOS)
        // Snapshotted, then read outside the lock: asking AVFoundation about a connection
        // while holding it invites a callback into this instrument on another thread.
        let outputs = guarded.withLock { $0.watched.allObjects }
        return outputs.contains { connections(of: $0).contains(where: isActiveAndEnabled) }
        #else
        return false
        #endif
    }

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass,
              let videoOutput = objc_getClass("AVCaptureVideoDataOutput") as? AnyClass
        else {
            return
        }

        // Catches the delegate assignment — `addOutput` says nothing about an existing one.
        hooks.announceSelf(
            class: videoOutput,
            atCallTakingTwo: Selector(("setSampleBufferDelegate:queue:")),
            on: videoOutput
        )
        hooks.trackArgument(
            class: videoOutput,
            at: Selector(("addOutput:")),
            on: session
        )
        #endif
    }

    func observe(_ context: Context) {
        #if os(iOS)
        guard let videoOutput = objc_getClass("AVCaptureVideoDataOutput") as? AnyClass else {
            return
        }

        context.follow(class: videoOutput) { [weak self] output, _ in
            self?.instrument(output, with: context)
        }

        // Emitted every interval, even empty — silence and a starved camera read the same.
        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self, self.isWatchingSomething, self.isCarrying else {
                // Drained anyway: what a stopped camera counted must not surface in the
                // window after it starts again, dated to the wrong second.
                _ = context.tally.take(Self.delivered)
                _ = context.tally.take(Self.dropped)
                _ = context.tally.take(Self.reason)
                _ = context.tally.take(Self.delegateDurationTotal)
                _ = context.tally.take(Self.delegateDurationPeak)
                return
            }

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.framesDeliveredCount(context.tally.take(Self.delivered)))
            out.put(.framesDroppedCount(context.tally.take(Self.dropped)))
            let weight = context.tally.take(Self.reason)
            if weight > 0 {
                out.put(.dropReason(Self.named(weight)))
            }
            out.put(.delegateDurationNanoseconds(context.tally.take(Self.delegateDurationTotal)))
            out.put(.delegateDurationPeakNanoseconds(context.tally.take(Self.delegateDurationPeak)))
        }
        #endif
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
    }

    #if os(iOS)
    private func instrument(_ output: AnyObject, with context: Context) {
        guarded.withLock { $0.watched.add(output) }
        guard let delegate = output.value(forKey: "sampleBufferDelegate") as AnyObject?,
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
            .sampleBufferCallback(subject, Self.didOutput) { _, _, _, _, elapsed in
                guard hot.isActive else {
                    return
                }

                hot.add(Self.delivered)
                hot.add(Self.delegateDurationTotal, elapsed)
                hot.raise(Self.delegateDurationPeak, to: elapsed)
            }
        let drop = context.swizzle
            .sampleBufferCallback(subject, Self.didDrop) { _, _, buffer, _, _ in
                guard hot.isActive else {
                    return
                }

                hot.add(Self.dropped)
                hot.raise(Self.reason, to: Self.weigh(buffer))
            }

        let deliveryHooked = delivery == .installed || delivery == .implemented
            || delivery == .joinedExisting
        let dropHooked = drop == .installed || drop == .implemented || drop == .joinedExisting
        guard deliveryHooked || dropHooked else {
            return
        }

        context.emit { out in
            out.put(.delegateClass(NSStringFromClass(subject)))
        }

        // Either callback — a delegate defining only `didDrop` left delivered frames at zero.
        guard delivery == .implemented || drop == .implemented else {
            return
        }

        guarded.withLock { $0.defined.insert(ObjectIdentifier(subject)) }
        rebind(output, delegate: delegate)
    }

    private func rebindIfDefined(
        _ output: AnyObject,
        delegate: AnyObject,
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
        _ output: AnyObject,
        delegate: AnyObject
    ) {
        guard let queue = output.value(forKey: "sampleBufferCallbackQueue") as AnyObject? else {
            return
        }

        let key = ObjectIdentifier(output)
        let alreadyRebinding = guarded.withLock { !$0.rebinding.insert(key).inserted }
        guard !alreadyRebinding else {
            return
        }

        _ = output.perform(
            Selector(("setSampleBufferDelegate:queue:")),
            with: delegate,
            with: queue
        )

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

final class CameraSessionConfiguration: Streamable, Configurable, LoadTimeInstall {
    struct Config: Codable, Sendable {
        let callers: Bool
    }

    static let id: InstrumentID = .cameraSessionConfiguration
    static let entity = Entity.ID.captureSession
    static let defaultConfig: Config = .init(callers: true)

    private let observations: Observations = .init()
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass else {
            return
        }

        hooks.trackSelf(
            class: session,
            atCallTaking: Selector(("addOutput:")),
            on: session
        )
        hooks.trackSelf(
            class: session,
            at: Selector(("startRunning")),
            on: session
        )
        #endif
    }

    func observe(_ context: Context) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass else {
            return
        }

        context.follow(class: session) { [weak self] session, instance in
            guard let self, let sessionObject = session as? NSObject else {
                return
            }

            // Emitted at attach and on every start/stop — a config that never runs still matters.
            self.observations.attach {
                [
                    Observation.attach(to: sessionObject, keyPath: "running") { [weak self] _ in
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
        _ session: AnyObject,
        instance: UInt32,
        into context: Context
    ) {
        let wired = connections(of: session)
        let active = wired.filter(isActiveAndEnabled)
        let inputs = session.value(forKey: "inputs") as? [AnyObject] ?? []
        let outputs = session.value(forKey: "outputs") as? [AnyObject] ?? []

        context.emit { out in
            out.put(.instanceId(instance))
            out.put(.sessionClass(String(describing: type(of: session))))
            out.put(.sessionPreset(session.value(forKey: "sessionPreset") as? String ?? ""))
            out.put(.inputCount(UInt32(inputs.count)))
            out.put(.outputCount(UInt32(outputs.count)))
            out.put(.connectionCount(UInt32(wired.count)))
            out.put(.activeConnectionCount(UInt32(active.count)))
            out.put(.sessionRunning((session.value(forKey: "isRunning") as? Bool) ?? false))

            if config.callers,
               let sessionClass = objc_getClass("AVCaptureSession") as? AnyClass
            {
                let own = CallerStack.inAppImages(
                    context.callers(class: sessionClass, instance: instance)
                )

                // Innermost first — arrival order is stack order, nothing needs numbering.
                for frame in own {
                    out.put(.frameAddress(frame))
                }
            }

            // Multi-cam only: the number a session refuses to start, configured but not running.
            if let multiCamClass = objc_getClass("AVCaptureMultiCamSession") as? AnyClass,
               session.isKind(of: multiCamClass)
            {
                if let hardwareCost = session.value(forKey: "hardwareCost") as? NSNumber {
                    out.put(.hardwareCostRatio(hardwareCost.floatValue))
                }
                if let systemPressureCost = session
                    .value(forKey: "systemPressureCost") as? NSNumber
                {
                    out.put(.systemPressureCostRatio(systemPressureCost.floatValue))
                }
            }
        }
    }
    #endif
}

final class CameraSessionState: Streamable, PlainInstrument, LoadTimeInstall {
    static let id: InstrumentID = .cameraSessionState
    static let entity = Entity.ID.captureSession

    private static let observed = ["running", "interrupted"]

    private let observations: Observations = .init()

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass else {
            return
        }

        hooks.trackSelf(
            class: session,
            atCallTaking: Selector(("addOutput:")),
            on: session
        )
        hooks.trackSelf(
            class: session,
            at: Selector(("startRunning")),
            on: session
        )
        #endif
    }

    func observe(_ context: Context) {
        #if os(iOS)
        guard let session = objc_getClass("AVCaptureSession") as? AnyClass else {
            return
        }

        context.follow(class: session) { [weak self] session, instance in
            guard let self, let sessionObject = session as? NSObject else {
                return
            }

            // One reading per change, one at attach — not per key path, or the value doubles up.
            self.observations.attach {
                Self.observed.map { keyPath in
                    Observation.attach(
                        to: sessionObject,
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
        _ session: AnyObject,
        instance: UInt32,
        into context: Context
    ) {
        context.emit { out in
            out.put(.instanceId(instance))
            out.put(.sessionRunning((session.value(forKey: "isRunning") as? Bool) ?? false))
            out.put(.sessionInterrupted((session.value(forKey: "isInterrupted") as? Bool) ?? false))
        }
    }
    #endif
}
