@testable import Basset
import BassetECS
import Foundation
import Testing

struct GPULatencyMeasurementTests {
    /// Wait rises under load, execution under throttling — reported apart since they differ.
    @Test func waitAndExecutionAreMeasuredApart() throws {
        let cost = try #require(
            GPULatency.measure(kernelEnd: 1.000, gpuStart: 1.004, gpuEnd: 1.005)
        )

        #expect(cost.wait == 4000000)
        #expect(cost.execution == 1000000)
    }

    /// A zero stamp means unset, not instant — face value reads it as a GPU answering instantly.
    @Test(arguments: [
        (0.0, 1.004, 1.005),
        (1.000, 0.0, 1.005),
        (1.000, 1.004, 0.0),
    ])
    func anUnstampedSubmissionIsRefused(_ stamps: (Double, Double, Double)) {
        #expect(GPULatency.measure(
            kernelEnd: stamps.0,
            gpuStart: stamps.1,
            gpuEnd: stamps.2
        ) == nil)
    }

    /// Backwards stamps would underflow into an enormous unsigned number if subtracted.
    @Test func stampsOutOfOrderAreRefused() {
        #expect(GPULatency.measure(kernelEnd: 2.0, gpuStart: 1.0, gpuEnd: 3.0) == nil)
        #expect(GPULatency.measure(kernelEnd: 1.0, gpuStart: 3.0, gpuEnd: 2.0) == nil)
    }

    @Test func aSubmissionThatWaitedNothingIsStillAMeasurement() throws {
        let cost = try #require(
            GPULatency.measure(kernelEnd: 1.0, gpuStart: 1.0, gpuEnd: 1.002)
        )

        #expect(cost.wait == 0)
        #expect(cost.execution == 2000000)
    }

    @Test func theBudgetIsAFrameAtTheDisplaysFastestRate() {
        #expect(GPULatency.frameBudgetNanoseconds(framesPerSecond: 60) == 16666666)
        #expect(GPULatency.frameBudgetNanoseconds(framesPerSecond: 120) == 8333333)
    }

    /// A display reporting nothing must not divide by zero or flag every probe as over budget.
    @Test func anUnknownRefreshRateFallsBackToSixty() {
        #expect(GPULatency.frameBudgetNanoseconds(framesPerSecond: 0) == 16666667)
        #expect(GPULatency.frameBudgetNanoseconds(framesPerSecond: -1) == 16666667)
    }
}

struct GPULatencyReadingTests {
    private enum Slot {
        static let submitted: TallySlot = .init(0)
        static let returned: TallySlot = .init(1)
        static let waitTotal: TallySlot = .init(2)
        static let waitPeak: TallySlot = .init(3)
        static let executionTotal: TallySlot = .init(4)
        static let executionPeak: TallySlot = .init(5)
        static let overBudget: TallySlot = .init(6)
    }

    @Test func awindowThatProbedNothingSaysNothing() {
        #expect(emit(from: Tally(slots: 7)).isEmpty)
    }

    @Test func areturnedProbeCarriesBothCostsAndTheBudgetItWasJudgedAgainst() {
        let tally = Tally(slots: 7)
        tally.add(Slot.submitted, 1)
        tally.add(Slot.returned, 1)
        tally.add(Slot.waitTotal, 4000000)
        tally.raise(Slot.waitPeak, to: 4000000)
        tally.add(Slot.executionTotal, 1000000)
        tally.raise(Slot.executionPeak, to: 1000000)

        let reading = emit(from: tally).first

        #expect(count(.gpuWaitNanoseconds, in: reading) == 4000000)
        #expect(count(.gpuExecutionNanoseconds, in: reading) == 1000000)
        #expect(count(.frameBudgetNanoseconds, in: reading) == 16666666)
    }

    /// A probe answered later must not report zero cost, as though the GPU replied instantly.
    @Test func aprobeStillInFlightReportsNoCosts() {
        let tally = Tally(slots: 7)
        tally.add(Slot.submitted, 1)

        let reading = emit(from: tally).first

        #expect(count(.sampleCount, in: reading) == 1)
        #expect(count(.occurrenceCount, in: reading) == 0)
        #expect(rendered(.gpuWaitNanoseconds, in: reading) == nil)
        #expect(rendered(.gpuExecutionNanoseconds, in: reading) == nil)
    }

    /// The other side of that boundary — an answer with no submission in its window still counts.
    @Test func ananswerArrivingWithoutItsSubmissionIsStillReported() {
        let tally = Tally(slots: 7)
        tally.add(Slot.returned, 1)
        tally.add(Slot.waitTotal, 900000)
        tally.raise(Slot.waitPeak, to: 900000)

        let reading = emit(from: tally).first

        #expect(count(.occurrenceCount, in: reading) == 1)
        #expect(count(.sampleCount, in: reading) == 0)
        #expect(count(.gpuWaitNanoseconds, in: reading) == 900000)
    }

    /// A flush between costs and their announcing count must keep the timings, not drop them.
    @Test func costsArrivingBeforeTheirAnswerAreKept() {
        let tally = Tally(slots: 7)
        tally.add(Slot.waitTotal, 4000000)
        tally.raise(Slot.waitPeak, to: 4000000)
        tally.add(Slot.executionTotal, 1000000)
        tally.raise(Slot.executionPeak, to: 1000000)

        let reading = emit(from: tally).first

        #expect(count(.gpuWaitNanoseconds, in: reading) == 4000000)
        #expect(count(.gpuExecutionNanoseconds, in: reading) == 1000000)
        #expect(count(.occurrenceCount, in: reading) == 0, "the answer had not landed")
    }

    @Test func aprobeOverTheBudgetIsCountedAndACleanOneIsNot() {
        let overBudget = Tally(slots: 7)
        overBudget.add(Slot.submitted, 1)
        overBudget.add(Slot.returned, 1)
        overBudget.add(Slot.overBudget, 1)

        let clean = Tally(slots: 7)
        clean.add(Slot.submitted, 1)
        clean.add(Slot.returned, 1)

        #expect(count(.overBudgetCount, in: emit(from: overBudget).first) == 1)
        #expect(rendered(.overBudgetCount, in: emit(from: clean).first) == nil)
    }

    @Test func awindowDrainsEverythingItReported() {
        let tally = Tally(slots: 7)
        tally.add(Slot.submitted, 1)
        tally.add(Slot.returned, 1)
        tally.add(Slot.waitTotal, 4000000)
        tally.raise(Slot.waitPeak, to: 4000000)
        tally.add(Slot.executionTotal, 1000000)
        tally.raise(Slot.executionPeak, to: 1000000)
        tally.add(Slot.overBudget, 1)

        _ = emit(from: tally)

        #expect(emit(from: tally).isEmpty, "a second window found nothing left")
    }

    /// Costs are drained even when unreported, or the next window inherits stale timings.
    @Test func awindowThatReportedNoCostsLeavesNoneBehind() {
        let tally = Tally(slots: 7)
        tally.add(Slot.submitted, 1)
        tally.add(Slot.waitTotal, 999)
        tally.raise(Slot.waitPeak, to: 999)

        _ = emit(from: tally)

        #expect(tally.read(Slot.waitTotal) == 0)
        #expect(tally.read(Slot.waitPeak) == 0)
    }

    private func emit(from tally: Tally) -> [Entity] {
        var out = Readings(entity: GPULatency.entity, instrumentName: GPULatency.name)
        GPULatency.write(
            tally,
            budget: GPULatency.frameBudgetNanoseconds(framesPerSecond: 60),
            over: Context.FlushWindow(nanoseconds: 1000000000),
            into: &out
        )
        guard !out.isEmpty else {
            return []
        }

        return [out.sealed()] + out.sealedSiblings()
    }

    private func rendered(_ id: Component.ID, in entity: Entity?) -> String? {
        entity?.components.first { $0.id == id }?.value.rendered
    }

    private func count(_ id: Component.ID, in entity: Entity?) -> UInt64? {
        rendered(id, in: entity).flatMap(UInt64.init)
    }
}

struct GPULatencyWiringTests {
    @Test func itDeclaresEveryCounterItWrites() {
        #expect(GPULatency.tallySlots == 7)
    }

    @Test func itIsRegisteredAndStreamsFromTheMetalDomain() throws {
        let registration = try #require(
            Instruments.all.first { $0.id == .metalGPULatency }
        )

        #expect(registration.name == "metal.gpu.latency")
        #expect(registration.domain == .metal)
        #expect(registration.delivery == .stream)
        #expect(registration.tallySlots == 7)
    }

    /// Confirms the watched class and selector exist rather than assumed from a header.
    @Test func theLayerClassAndSelectorExist() throws {
        let layer = try #require(objc_getClass("CAMetalLayer") as? AnyClass)

        #expect(layer.instancesRespond(to: NSSelectorFromString("nextDrawable")))
    }

    @Test func itRefusesToRunOnASimulator() {
        #expect(InstrumentID.metalGPULatency.availability.simulator == false)
    }

    /// The menu entry must say the GPU is given work — this instrument perturbs what it measures.
    @Test func themetadataSaysItSubmitsWorkOfItsOwn() {
        let metadata = InstrumentID.metalGPULatency.metadata

        #expect(metadata.summary.lowercased().contains("trivial"))
        #expect(metadata.overhead == .medium)
    }
}
