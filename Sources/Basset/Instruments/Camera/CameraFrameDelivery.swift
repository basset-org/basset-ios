import BassetECS
import Foundation
#if os(iOS)
import AVFoundation
import CoreMedia
import ObjectiveC
#endif

final class CameraFrameDelivery: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .cameraFrameDelivery
    static let entity = Entity.WireID.videoFrames

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

    private let lock: NSLock = .init()
    private var instrumented: Set<ObjectIdentifier> = []
    private var watching = 0

    private var isWatchingSomething: Bool {
        lock.lock()
        defer { lock.unlock() }
        return watching > 0
    }

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        #if os(iOS)
        hooks.catchSelf(
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

        // Emitted on every interval, including the ones where nothing
        // arrived. A silent instrument and a camera delivering no frames
        // read the same in a capture, and the second is the answer the
        // request was opened for.
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
        lock.lock()
        instrumented.removeAll()
        watching = 0
        lock.unlock()
    }

    #if os(iOS)
    private func instrument(_ output: AVCaptureVideoDataOutput, with context: Context) {
        guard let delegate = output.sampleBufferDelegate,
              let subject = object_getClass(delegate)
        else {
            return
        }

        // Per delegate class, not per output: the hook rewrites a method on
        // the class, so a second output sharing the delegate's type would
        // otherwise add a second observer and count every frame twice.
        lock.lock()
        let fresh = instrumented.insert(ObjectIdentifier(subject)).inserted
        if fresh {
            watching += 1
        }
        lock.unlock()
        guard fresh else {
            return
        }

        let hot = context.hotPath
        _ = context.swizzle.sampleBufferCallback(subject, Self.didOutput) { _, _, _, _ in
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

        // AVFoundation reads a delegate's callbacks once, when it is named.
        // A method defined after that moment is one it will never ask for,
        // so the delegate is named again — the same object on the same
        // queue, which is what it was already set to.
        if drop == .implemented, let queue = output.sampleBufferCallbackQueue {
            output.setSampleBufferDelegate(delegate, queue: queue)
        }
    }

    /// Highest weight wins the interval, so the reason that explains a stall
    /// survives alongside the ones that merely accompany it.
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
