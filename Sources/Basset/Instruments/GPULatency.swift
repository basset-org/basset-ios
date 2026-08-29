import BassetEntityComponent
import Foundation

#if canImport(Metal)
import Metal
import QuartzCore
#endif

#if canImport(UIKit)
import UIKit
#endif

/// GPU busyness measured by trivial work and timing the wait — the SDK's one active instrument.
final class GPULatency: Streamable, PlainInstrument {
    enum Slot {
        static let submitted: TallySlot = .init(0)
        static let returned: TallySlot = .init(1)
        static let waitTotal: TallySlot = .init(2)
        static let waitPeak: TallySlot = .init(3)
        static let executionTotal: TallySlot = .init(4)
        static let executionPeak: TallySlot = .init(5)
        static let overBudget: TallySlot = .init(6)
    }

    /// Holds the harness across two closures; a class since `Mutex` is noncopyable, uncapturable.
    private final class SharedHarness: @unchecked Sendable {
        #if canImport(Metal)
        private let guarded: Mutex<Harness?> = .init(nil)

        var isEmpty: Bool {
            guarded.withLock { $0 == nil }
        }

        var current: Harness? {
            guarded.withLock { $0 }
        }

        func fillIfEmpty(_ build: () -> Harness?) {
            guard isEmpty, let built = build() else {
                return
            }

            guarded.withLock { current in
                if current == nil {
                    current = built
                }
            }
        }

        func clear() {
            guarded.withLock { $0 = nil }
        }
        #else
        func clear() {}
        #endif
    }

    static let id: InstrumentID = .metalGPULatency
    static let tallySlots = 7

    /// Once a second — the work is trivial, so this bounds how often the GPU gets interrupted.
    private static let interval: Duration = .seconds(1)

    /// Small enough not to matter, big enough to be real work — noticing it is the finding.
    private static let probeBytes = 4096

    private static let layerClassName = "CAMetalLayer"
    private static let nextDrawableSelector = "nextDrawable"

    private let harness: SharedHarness = .init()
    private let budget: SharedBudget = .init()

    init() {}

    static func write(
        _ tally: Tally,
        budget: UInt64,
        over elapsed: Context.FlushWindow,
        into out: inout Readings
    ) {
        // Drained before deciding anything: a probe submitted in one window is answered in another.
        let submitted = tally.take(Slot.submitted)
        let returned = tally.take(Slot.returned)
        let waitTotal = tally.take(Slot.waitTotal)
        let waitPeak = tally.take(Slot.waitPeak)
        let executionTotal = tally.take(Slot.executionTotal)
        let executionPeak = tally.take(Slot.executionPeak)
        let overBudget = tally.take(Slot.overBudget)

        // Written before the count announcing them, so a window can hold timings with no answer.
        let measured = waitTotal > 0 || executionTotal > 0
        guard submitted > 0 || returned > 0 || measured else {
            return
        }

        out.put(.windowNanoseconds(elapsed.nanoseconds))
        out.put(.sampleCount(submitted))
        out.put(.occurrenceCount(returned))
        out.put(.frameBudgetNanoseconds(budget))

        // Absent, not zero, when nothing was timed — a probe in flight didn't answer instantly.
        guard returned > 0 || measured else {
            return
        }

        out.put(.gpuWaitNanoseconds(waitTotal))
        out.put(.gpuWaitPeakNanoseconds(waitPeak))
        out.put(.gpuExecutionNanoseconds(executionTotal))
        out.put(.gpuExecutionPeakNanoseconds(executionPeak))
        if overBudget > 0 {
            out.put(.overBudgetCount(overBudget))
        }
    }

    /// `nil` when a stamp is unset or the pair runs backwards, rather than reporting zero elapsed.
    static func measure(
        kernelEnd: Double,
        gpuStart: Double,
        gpuEnd: Double
    ) -> (wait: UInt64, execution: UInt64)? {
        guard kernelEnd > 0, gpuStart > 0, gpuEnd > 0,
              gpuStart >= kernelEnd, gpuEnd >= gpuStart
        else {
            return nil
        }

        // Rounded, not truncated — seconds as Double, and truncating biases every result low.
        return (
            UInt64(((gpuStart - kernelEnd) * 1000000000).rounded()),
            UInt64(((gpuEnd - gpuStart) * 1000000000).rounded())
        )
    }

    /// Rides in the reading, not assumed by the reader, so a 120 Hz capture still reads on 60 Hz.
    static func frameBudgetNanoseconds(framesPerSecond: Int) -> UInt64 {
        guard framesPerSecond > 0 else {
            return 16666667
        }

        return UInt64(1000000000 / framesPerSecond)
    }

    /// Main-actor `UIScreen` read once, cached; 60fps fallback until it answers, or on non-iOS.
    private static func readDisplayRate(into budget: SharedBudget) {
        #if canImport(UIKit) && os(iOS)
        DispatchQueue.main.async {
            budget.set(frameBudgetNanoseconds(
                framesPerSecond: UIScreen.main.maximumFramesPerSecond
            ))
        }
        #endif
    }

    func observe(_ context: Context) {
        #if canImport(Metal)
        guard let layer = objc_getClass(Self.layerClassName) as? AnyClass else {
            context.emit(.gpu) { out in
                out.put(.mechanismStatus("unavailable: this app does not use Metal"))
            }
            return
        }

        let budget = self.budget
        Self.readDisplayRate(into: budget)
        let harness = self.harness

        // Comes from a layer the app already draws through; nothing probed until one appears.
        _ = context.swizzle.afterFactory(
            layer,
            NSSelectorFromString(Self.nextDrawableSelector)
        ) { receiver, _ in
            harness.fillIfEmpty {
                guard let metalLayer = receiver as? CAMetalLayer,
                      let device = metalLayer.device
                else {
                    return nil
                }

                return Harness(device: device, bytes: Self.probeBytes)
            }
        }

        // Reported before the next probe is sent, so a window carries the prior probe's answer.
        context.flush(every: Self.interval, into: .gpu) {
            [tally = context.tally, hot = context.hotPath] out, elapsed in
            let frame = budget.current
            Self.write(tally, budget: frame, over: elapsed, into: &out)
            harness.current?.submit(budget: frame, hot: hot)
        }
        #endif
    }

    func stopObserving() {
        harness.clear()
    }
}

/// The frame budget a probe is judged against, settled on the main thread once the instrument runs.
final class SharedBudget: @unchecked Sendable {
    private let guarded: Mutex<UInt64> = .init(16666667)

    var current: UInt64 {
        guarded.withLock { $0 }
    }

    func set(_ nanoseconds: UInt64) {
        guarded.withLock { $0 = nanoseconds }
    }
}

#if canImport(Metal)
/// Made once a device appears: its own queue so submissions aren't reordered, plus a buffer.
private final class Harness: @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let buffer: MTLBuffer
    private let bytes: Int

    init?(device: MTLDevice, bytes: Int) {
        guard let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: bytes, options: .storageModePrivate)
        else {
            return nil
        }

        self.queue = queue
        self.buffer = buffer
        self.bytes = bytes
    }

    func submit(budget: UInt64, hot: HotPath) {
        guard hot.isActive,
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder()
        else {
            return
        }

        blit.fill(buffer: buffer, range: 0 ..< bytes, value: 0)
        blit.endEncoding()

        commands.addCompletedHandler { finished in
            guard hot.isActive,
                  let cost = GPULatency.measure(
                      kernelEnd: finished.kernelEndTime,
                      gpuStart: finished.gpuStartTime,
                      gpuEnd: finished.gpuEndTime
                  )
            else {
                return
            }

            // Published before the count announcing them, so a mid-handler flush sees no zeros.
            hot.add(GPULatency.Slot.waitTotal, cost.wait)
            hot.raise(GPULatency.Slot.waitPeak, to: cost.wait)
            hot.add(GPULatency.Slot.executionTotal, cost.execution)
            hot.raise(GPULatency.Slot.executionPeak, to: cost.execution)
            if cost.wait + cost.execution > budget {
                hot.add(GPULatency.Slot.overBudget)
            }
            hot.add(GPULatency.Slot.returned)
        }

        hot.add(GPULatency.Slot.submitted)
        commands.commit()
    }
}
#endif
