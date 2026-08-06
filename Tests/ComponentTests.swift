@testable import Basset
import BassetECS
import Testing

struct ComponentTests {
    @Test(arguments: [
        (Component.fps(60), Scalar.float32),
        (Component.methodDurationMilliseconds(1), Scalar.float32),
        (Component.memoryUsedBytes(4096), Scalar.uint64),
        (Component.deviceModel("iPhone17,2"), Scalar.string),
        (Component.sessionRunning(true), Scalar.bool),
    ])
    func wireTagsEachValueWithItsScalar(_ pair: (Component, Scalar)) {
        #expect(pair.0.wire.value.scalar == pair.1)
    }

    @Test func idAndValueComeFromTheSameCase() {
        let component = Component.cpuUsageRatio(0.29)
        #expect(component.id == .cpuUsageRatio)
        #expect(component.value == .float32(0.29))
    }

    @Test func everyCaseClaimsADistinctWireId() {
        let all: [Component] = [
            .cpuUsageRatio(0), .fps(0), .deviceId(""), .source(""), .methodName(""),
            .methodDurationMilliseconds(0), .deviceModel(""), .osVersion(""),
            .appVersion(""),
            .userId(""), .serverVersion(""), .memoryUsedBytes(0), .thermalState(""),
            .detail(""), .instrument(0), .bundleId(""), .buildConfiguration(""),
            .deviceKind(""), .passCount(0), .totalNanoseconds(0),
            .peakNanoseconds(0), .sessionRunning(false), .sessionInterrupted(false),
            .viewControllerClass(""),
        ]
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func valueScalarMatchesCase() {
        #expect(ComponentValue.string("x").scalar == .string)
        #expect(ComponentValue.float32(1).scalar == .float32)
        #expect(ComponentValue.uint64(1).scalar == .uint64)
        #expect(ComponentValue.bool(true).scalar == .bool)
    }

    /// A retired id stays a reservation rather than being deleted: the wire is
    /// grow-only, and a reused number decodes every stored artifact wrong.
    @Test func retiredIdsStayReserved() {
        #expect(Component.WireID.retiredInstrumentVersion.rawValue == 16)
        #expect(Component.WireID.retiredLayoutTotalDuration.rawValue == 21)
        #expect(Component.WireID.retiredLayoutMaxDuration.rawValue == 22)
    }

    /// The unit lives in the component's name, not in a table beside it. A
    /// duration cannot be minted without saying which unit, because the name is
    /// the only place it could go — and names are off-wire, so this costs nothing
    /// on the frame.
    @Test func everyMeasuredComponentNamesItsUnit() {
        let measured: [Component.WireID] = [
            .memoryUsedBytes, .methodDurationMilliseconds, .totalNanoseconds,
            .peakNanoseconds, .passCount, .cpuUsageRatio, .hardwareCostRatio,
            .systemPressureCostRatio, .formatWidthPixels, .formatHeightPixels,
            .formatMinFramesPerSecond, .formatMaxFramesPerSecond,
            .videoRotationDegrees, .framesDeliveredCount, .framesDroppedCount,
            .inputCount, .outputCount, .connectionCount, .activeConnectionCount,
            .formatCount,
        ]
        let units = [
            "Bytes", "Milliseconds", "Nanoseconds", "Count", "Ratio", "fps",
            "Pixels", "PerSecond", "Degrees",
        ]

        for id in measured {
            #expect(
                units.contains { "\(id)".localizedCaseInsensitiveContains($0) },
                "\(id) does not say what it is measured in"
            )
        }
    }

    /// Milliseconds as a Float lost a 119ns layout pass to rounding and left the
    /// unit unrecoverable. The replacement is what the monotonic clock returns.
    @Test func layoutDurationsAreIntegerNanoseconds() {
        #expect(Component.totalNanoseconds(12296).value == .uint64(12296))
        #expect(Component.peakNanoseconds(373667).value == .uint64(373667))
    }
}
