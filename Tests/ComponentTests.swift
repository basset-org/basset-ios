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
        #expect(pair.0.value.scalar == pair.1)
    }

    @Test func idAndValueComeFromTheSameCase() {
        let component = Component.cpuUsageRatio(0.29)
        #expect(component.id == .cpuUsageRatio)
        #expect(component.value == .float32(0.29))
    }

    /// Every component that can be made, and the id each one claims.
    ///
    /// A case is paired to its id in exactly one place — the `wire` switch — and
    /// nothing else states it, so an arm naming the wrong id compiles. The value
    /// then lands under another component's number, overwrites that component's
    /// reading, and the id is grow-only, so every artifact already written stays
    /// wrong. One wrong arm leaves two cases claiming one id and one id claimed
    /// by nobody, which is what the counts below catch.
    @Test func everyCaseClaimsADistinctId() {
        let all: [Component] = [
            .cpuUsageRatio(0), .fps(0), .deviceId(""), .source(""), .methodName(""),
            .methodDurationMilliseconds(0), .deviceModel(""), .osVersion(""),
            .appVersion(""), .userId(""), .serverVersion(""), .memoryUsedBytes(0),
            .thermalState(""), .detail(""), .instrument(0), .bundleId(""),
            .buildConfiguration(""), .deviceKind(""), .passCount(0),
            .totalNanoseconds(0), .peakNanoseconds(0), .sessionRunning(false),
            .sessionInterrupted(false), .viewControllerClass(""), .instanceId(0),
            .httpStatusCode(0), .negotiatedProtocol(""), .bytesSentCount(0),
            .bytesReceivedCount(0), .requestURL(""), .connectionReused(false),
            .interfaceKind(""), .pathSatisfied(false), .expensiveInterface(false),
            .constrainedInterface(false), .unsatisfiedReason(""), .errorDomain(""),
            .errorCode(0), .appState(""), .sessionClass(""), .sessionPreset(""),
            .inputCount(0), .outputCount(0), .connectionCount(0),
            .activeConnectionCount(0), .hardwareCostRatio(0),
            .systemPressureCostRatio(0), .systemPressureLevel(""), .deviceType(""),
            .devicePosition(""), .deviceUniqueId(""), .formatWidthPixels(0),
            .formatHeightPixels(0), .formatPixelFormat(""),
            .formatMinFramesPerSecond(0), .formatMaxFramesPerSecond(0),
            .formatMultiCamSupported(false), .formatCount(0), .activeColorSpace(""),
            .videoRotationDegrees(0), .videoMirrored(false), .multiCamSetIndex(0),
            .multiCamSetMembers(""), .outputPixelFormat(""),
            .outputPixelFormatSupported(false), .framesDeliveredCount(0),
            .framesDroppedCount(0), .dropReason(""), .hangNanoseconds(0),
            .hangResolved(false), .runLoopTurnCount(0), .threadIndex(0),
            .threadName(""), .threadIsMain(false), .frameAddress(0), .imageName(""),
            .imageLoadAddress(0), .imageUUID(""), .buildUUID(""), .launchId(0),
            .logSubsystem(""), .logCategory(""), .logMessage(""),
            .occurrenceCount(0), .hostRootViewType(""), .hostRootViewOpaque(false),
            .hostNavigationTitle(""), .hostAppearNanoseconds(0), .hostKind(""),
            .hostCount(0), .hostViewClass(""), .mechanismStatus(""),
            .displayListSeed(0), .displayListItemCount(0),
            .displayListChangeCount(0), .ivarPathGeneration(""),
            .presentationKind(""), .presentedRootViewType(""), .windowNanoseconds(0),
            .memoryLimitBytes(0), .memoryAvailableBytes(0), .memoryPressureLevel(""),
            .memoryPressureScope(""), .exitReason(""), .intervalEndMicroseconds(0),
            .permissionSubject(""), .authorizationStatus(""),
            .usageDescriptionDeclared(false), .threadIdentifier(0),
            .threadRunState(""), .threadIdle(false), .threadPriority(0),
            .threadBasePriority(0), .cpuNanoseconds(0), .wakeupCount(0),
            .idleWakeupCount(0), .queueLatencyNanoseconds(0), .queueLabel(""),
            .insertedCount(0), .updatedCount(0), .deletedCount(0),
            .refreshedCount(0), .contextConcurrency(""),
            .confinementViolation(false), .logLevel(""), .dnsNanoseconds(0),
            .connectNanoseconds(0), .tlsNanoseconds(0), .serverNanoseconds(0),
            .responseNanoseconds(0), .tlsVersion(""), .tlsCipherSuite(""),
            .transactionCount(0), .requestTimeoutSeconds(0),
            .resourceTimeoutSeconds(0), .allowsCellular(false),
            .allowsExpensive(false), .allowsConstrained(false),
            .waitsForConnectivity(false), .maximumConnectionsPerHost(0),
            .cachePolicy(""), .dnsProtocol(""), .remoteAddress(""),
            .proxyConnection(false), .multipath(false),
            .arbitraryLoadsAllowed(false), .exceptionDomain(""),
            .insecureLoadsAllowed(false), .minimumTLSVersion(""),
            .deadlineMissCount(0), .deadlineOverrunNanoseconds(0),
            .presentationLatencyNanoseconds(0), .settingName(""),
            .settingEnabled(false), .textSizeCategory(""),
            .accessibilityTextSize(false), .languageCode(""), .regionCode(""),
            .calendarIdentifier(""), .usesMetricSystem(false),
            .uses24HourTime(false), .layoutDirection(""), .syncEventType(""),
            .syncSucceeded(false), .changeReason(""), .changedKeyCount(0),
            .notificationSetting(""), .settingState(""), .alertStyle(""),
            .previewVisibility(""), .callbackImplemented(false),
            .silenceNanoseconds(0), .accuracyClass(""), .callbackCount(0),
            .delegateClass(""), .bluetoothState(""), .contentProcessTerminations(0),
            .tileLoadFailures(0), .mapLoadsCompleted(0), .callAction(""),
            .audioOutputPort(""), .audioOutputName(""), .audioInputPort(""),
            .audioCategory(""), .audioMode(""), .audioCategoryOptions(""),
            .audioPreviousOutputPort(""), .audioRouteVerdict(""), .outputVolume(0),
            .otherAudioPlaying(false), .secondaryAudioSilenced(false),
        ]

        #expect(Set(all.map(\.id)).count == all.count)

        // The ids nothing can construct are the retired ones, and only those. A
        // retired number is never reissued, so it keeps its case and loses its
        // constructor; any other unclaimed id means a component lost its way to
        // the wire.
        let claimed = Set(all.map(\.id))
        let unclaimed = Component.ID.allCases.filter { !claimed.contains($0) }
        #expect(unclaimed == [
            .retiredInstrumentVersion,
            .retiredLayoutTotalDuration,
            .retiredLayoutMaxDuration,
        ])
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
        #expect(Component.ID.retiredInstrumentVersion.rawValue == 16)
        #expect(Component.ID.retiredLayoutTotalDuration.rawValue == 21)
        #expect(Component.ID.retiredLayoutMaxDuration.rawValue == 22)
    }

    /// The unit lives in the component's name, not in a table beside it. A
    /// duration cannot be minted without saying which unit, because the name is
    /// the only place it could go — and names are off-wire, so this costs nothing
    /// on the frame.
    @Test func everyMeasuredComponentNamesItsUnit() {
        let measured: [Component.ID] = [
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
