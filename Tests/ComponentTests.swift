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

    /// A transposed id passes a uniqueness check but swaps every reading it names.
    @Test func everyFactoryClaimsTheIdItIsNamedFor() {
        let all: [(Component, Component.ID)] = [
            (.cpuUsageRatio(0), .cpuUsageRatio), (.fps(0), .fps),
            (.deviceId(""), .deviceId), (.source(""), .source),
            (.methodName(""), .methodName),
            (.methodDurationMilliseconds(0), .methodDurationMilliseconds),
            (.deviceModel(""), .deviceModel), (.osVersion(""), .osVersion),
            (.appVersion(""), .appVersion), (.userId(""), .userId),
            (.serverVersion(""), .serverVersion),
            (.memoryUsedBytes(0), .memoryUsedBytes),
            (.thermalState(""), .thermalState), (.detail(""), .detail),
            (.instrument(0), .instrument), (.bundleId(""), .bundleId),
            (.buildConfiguration(""), .buildConfiguration),
            (.deviceKind(""), .deviceKind), (.sdkVersion(""), .sdkVersion),
            (.passCount(0), .passCount),
            (.totalNanoseconds(0), .totalNanoseconds),
            (.peakNanoseconds(0), .peakNanoseconds),
            (.sessionRunning(false), .sessionRunning),
            (.sessionInterrupted(false), .sessionInterrupted),
            (.viewControllerClass(""), .viewControllerClass),
            (.instanceId(0), .instanceId), (.httpStatusCode(0), .httpStatusCode),
            (.negotiatedProtocol(""), .negotiatedProtocol),
            (.bytesSentCount(0), .bytesSentCount),
            (.bytesReceivedCount(0), .bytesReceivedCount),
            (.requestURL(""), .requestURL),
            (.connectionReused(false), .connectionReused),
            (.interfaceKind(""), .interfaceKind),
            (.pathSatisfied(false), .pathSatisfied),
            (.expensiveInterface(false), .expensiveInterface),
            (.constrainedInterface(false), .constrainedInterface),
            (.unsatisfiedReason(""), .unsatisfiedReason),
            (.errorDomain(""), .errorDomain), (.errorCode(0), .errorCode),
            (.appState(""), .appState), (.sessionClass(""), .sessionClass),
            (.sessionPreset(""), .sessionPreset), (.inputCount(0), .inputCount),
            (.outputCount(0), .outputCount), (.connectionCount(0), .connectionCount),
            (.activeConnectionCount(0), .activeConnectionCount),
            (.hardwareCostRatio(0), .hardwareCostRatio),
            (.systemPressureCostRatio(0), .systemPressureCostRatio),
            (.systemPressureLevel(""), .systemPressureLevel),
            (.deviceType(""), .deviceType), (.devicePosition(""), .devicePosition),
            (.deviceUniqueId(""), .deviceUniqueId),
            (.formatWidthPixels(0), .formatWidthPixels),
            (.formatHeightPixels(0), .formatHeightPixels),
            (.formatPixelFormat(""), .formatPixelFormat),
            (.formatMinFramesPerSecond(0), .formatMinFramesPerSecond),
            (.formatMaxFramesPerSecond(0), .formatMaxFramesPerSecond),
            (.formatMultiCamSupported(false), .formatMultiCamSupported),
            (.formatCount(0), .formatCount),
            (.activeColorSpace(""), .activeColorSpace),
            (.videoRotationDegrees(0), .videoRotationDegrees),
            (.videoMirrored(false), .videoMirrored),
            (.multiCamSetIndex(0), .multiCamSetIndex),
            (.multiCamSetMembers(""), .multiCamSetMembers),
            (.outputPixelFormat(""), .outputPixelFormat),
            (.outputPixelFormatSupported(false), .outputPixelFormatSupported),
            (.framesDeliveredCount(0), .framesDeliveredCount),
            (.framesDroppedCount(0), .framesDroppedCount),
            (.dropReason(""), .dropReason),
            (.delegateDurationNanoseconds(0), .delegateDurationNanoseconds),
            (.delegateDurationPeakNanoseconds(0), .delegateDurationPeakNanoseconds),
            (.hangNanoseconds(0), .hangNanoseconds),
            (.hangResolved(false), .hangResolved),
            (.runLoopTurnCount(0), .runLoopTurnCount),
            (.threadIndex(0), .threadIndex), (.threadName(""), .threadName),
            (.threadIsMain(false), .threadIsMain), (.frameAddress(0), .frameAddress),
            (.imageName(""), .imageName), (.imageLoadAddress(0), .imageLoadAddress),
            (.imageUUID(""), .imageUUID), (.buildUUID(""), .buildUUID),
            (.launchId(0), .launchId), (.logSubsystem(""), .logSubsystem),
            (.logCategory(""), .logCategory), (.logMessage(""), .logMessage),
            (.occurrenceCount(0), .occurrenceCount),
            (.hostRootViewType(""), .hostRootViewType),
            (.hostRootViewOpaque(false), .hostRootViewOpaque),
            (.hostNavigationTitle(""), .hostNavigationTitle),
            (.hostAppearNanoseconds(0), .hostAppearNanoseconds),
            (.hostKind(""), .hostKind), (.hostCount(0), .hostCount),
            (.hostViewClass(""), .hostViewClass),
            (.mechanismStatus(""), .mechanismStatus),
            (.displayListSeed(0), .displayListSeed),
            (.displayListItemCount(0), .displayListItemCount),
            (.displayListChangeCount(0), .displayListChangeCount),
            (.ivarPathGeneration(""), .ivarPathGeneration),
            (.presentationKind(""), .presentationKind),
            (.presentedRootViewType(""), .presentedRootViewType),
            (.windowNanoseconds(0), .windowNanoseconds),
            (.memoryLimitBytes(0), .memoryLimitBytes),
            (.memoryAvailableBytes(0), .memoryAvailableBytes),
            (.memoryPressureLevel(""), .memoryPressureLevel),
            (.memoryPressureScope(""), .memoryPressureScope),
            (.exitReason(""), .exitReason),
            (.intervalEndMicroseconds(0), .intervalEndMicroseconds),
            (.permissionSubject(""), .permissionSubject),
            (.authorizationStatus(""), .authorizationStatus),
            (.usageDescriptionDeclared(false), .usageDescriptionDeclared),
            (.threadIdentifier(0), .threadIdentifier),
            (.threadRunState(""), .threadRunState),
            (.threadIdle(false), .threadIdle), (.threadPriority(0), .threadPriority),
            (.threadBasePriority(0), .threadBasePriority),
            (.cpuNanoseconds(0), .cpuNanoseconds), (.wakeupCount(0), .wakeupCount),
            (.idleWakeupCount(0), .idleWakeupCount),
            (.queueLatencyNanoseconds(0), .queueLatencyNanoseconds),
            (.queueLabel(""), .queueLabel), (.insertedCount(0), .insertedCount),
            (.updatedCount(0), .updatedCount), (.deletedCount(0), .deletedCount),
            (.refreshedCount(0), .refreshedCount),
            (.contextConcurrency(""), .contextConcurrency),
            (.confinementViolation(false), .confinementViolation),
            (.logLevel(""), .logLevel), (.dnsNanoseconds(0), .dnsNanoseconds),
            (.connectNanoseconds(0), .connectNanoseconds),
            (.tlsNanoseconds(0), .tlsNanoseconds),
            (.serverNanoseconds(0), .serverNanoseconds),
            (.responseNanoseconds(0), .responseNanoseconds),
            (.tlsVersion(""), .tlsVersion), (.tlsCipherSuite(""), .tlsCipherSuite),
            (.transactionCount(0), .transactionCount),
            (.requestTimeoutSeconds(0), .requestTimeoutSeconds),
            (.resourceTimeoutSeconds(0), .resourceTimeoutSeconds),
            (.allowsCellular(false), .allowsCellular),
            (.allowsExpensive(false), .allowsExpensive),
            (.allowsConstrained(false), .allowsConstrained),
            (.waitsForConnectivity(false), .waitsForConnectivity),
            (.maximumConnectionsPerHost(0), .maximumConnectionsPerHost),
            (.cachePolicy(""), .cachePolicy), (.dnsProtocol(""), .dnsProtocol),
            (.remoteAddress(""), .remoteAddress),
            (.proxyConnection(false), .proxyConnection),
            (.multipath(false), .multipath),
            (.arbitraryLoadsAllowed(false), .arbitraryLoadsAllowed),
            (.exceptionDomain(""), .exceptionDomain),
            (.insecureLoadsAllowed(false), .insecureLoadsAllowed),
            (.minimumTLSVersion(""), .minimumTLSVersion),
            (.deadlineMissCount(0), .deadlineMissCount),
            (.deadlineOverrunNanoseconds(0), .deadlineOverrunNanoseconds),
            (.presentationLatencyNanoseconds(0), .presentationLatencyNanoseconds),
            (.settingName(""), .settingName),
            (.settingEnabled(false), .settingEnabled),
            (.textSizeCategory(""), .textSizeCategory),
            (.accessibilityTextSize(false), .accessibilityTextSize),
            (.languageCode(""), .languageCode), (.regionCode(""), .regionCode),
            (.calendarIdentifier(""), .calendarIdentifier),
            (.usesMetricSystem(false), .usesMetricSystem),
            (.uses24HourTime(false), .uses24HourTime),
            (.layoutDirection(""), .layoutDirection),
            (.changeReason(""), .changeReason),
            (.notificationSetting(""), .notificationSetting),
            (.settingState(""), .settingState), (.alertStyle(""), .alertStyle),
            (.previewVisibility(""), .previewVisibility),
            (.callbackImplemented(false), .callbackImplemented),
            (.silenceNanoseconds(0), .silenceNanoseconds),
            (.accuracyClass(""), .accuracyClass),
            (.callbackCount(0), .callbackCount),
            (.delegateClass(""), .delegateClass),
            (.bluetoothState(""), .bluetoothState),
            (.contentProcessTerminations(0), .contentProcessTerminations),
            (.tileLoadFailures(0), .tileLoadFailures),
            (.mapLoadsCompleted(0), .mapLoadsCompleted),
            (.callAction(""), .callAction), (.audioOutputPort(""), .audioOutputPort),
            (.audioOutputName(""), .audioOutputName),
            (.audioInputPort(""), .audioInputPort),
            (.audioCategory(""), .audioCategory), (.audioMode(""), .audioMode),
            (.audioCategoryOptions(""), .audioCategoryOptions),
            (.audioPreviousOutputPort(""), .audioPreviousOutputPort),
            (.audioRouteVerdict(""), .audioRouteVerdict),
            (.audioInputVerdict(""), .audioInputVerdict),
            (.audioInputName(""), .audioInputName),
            (.audioInputDataSource(""), .audioInputDataSource),
            (.audioInputPolarPattern(""), .audioInputPolarPattern),
            (.audioInputOrientation(""), .audioInputOrientation),
            (.audioInputAvailable(false), .audioInputAvailable),
            (.audioPreferredInputHonored(false), .audioPreferredInputHonored),
            (.availableInputCount(0), .availableInputCount),
            (.audioOutputCount(0), .audioOutputCount),
            (.outputVolume(0), .outputVolume),
            (.otherAudioPlaying(false), .otherAudioPlaying),
            (.secondaryAudioSilenced(false), .secondaryAudioSilenced),
            (.sampleCount(0), .sampleCount),
            (.unwindFailureCount(0), .unwindFailureCount),
            (.drawableRequestCount(0), .drawableRequestCount),
            (.drawableSkippedCount(0), .drawableSkippedCount),
            (.drawableUnavailableCount(0), .drawableUnavailableCount),
            (.gpuWaitNanoseconds(0), .gpuWaitNanoseconds),
            (.gpuWaitPeakNanoseconds(0), .gpuWaitPeakNanoseconds),
            (.gpuExecutionNanoseconds(0), .gpuExecutionNanoseconds),
            (.gpuExecutionPeakNanoseconds(0), .gpuExecutionPeakNanoseconds),
            (.frameBudgetNanoseconds(0), .frameBudgetNanoseconds),
            (.overBudgetCount(0), .overBudgetCount),
            (.imageTextBytes(0), .imageTextBytes),
            (.bundledImageCount(0), .bundledImageCount),
            (.methodClass(""), .methodClass),
            (.ownedByDeclaringImage(false), .ownedByDeclaringImage),
            (.implementationInMappedImage(false), .implementationInMappedImage),
            (.threadRequestedQos(""), .threadRequestedQos),
            (.touchPhase(""), .touchPhase),
            (.activeTouchCount(0), .activeTouchCount),
            (.touchesMovedCount(0), .touchesMovedCount),
            (.dragDistancePoints(0), .dragDistancePoints),
            (.maximumSimultaneousTouchCount(0), .maximumSimultaneousTouchCount),
            (.touchId(0), .touchId),
            (.originXPoints(0), .originXPoints),
            (.originYPoints(0), .originYPoints),
            (.frameWidthPoints(0), .frameWidthPoints),
            (.frameHeightPoints(0), .frameHeightPoints),
            (.runtimeClassName(""), .runtimeClassName),
            (.gestureRecognizerState(""), .gestureRecognizerState),
            (.viewId(0), .viewId),
            (.viewParent(0), .viewParent),
            (.nestedLevel(0), .nestedLevel),
            (.faultId(0), .faultId),
            (.renderDestination(""), .renderDestination),
            (.textureBackedImageCount(0), .textureBackedImageCount),
            (.emptyResultCount(0), .emptyResultCount),
            (.debuggerAttached(false), .debuggerAttached),
            (.interfaceOrientation(""), .interfaceOrientation),
        ]

        for (component, expected) in all {
            #expect(component.id == expected)
        }
        #expect(Set(all.map(\.1)).count == all.count)

        // Unclaimed ids are retired ones — nothing else should be missing here.
        let claimed = Set(all.map(\.1))
        let unclaimed = Component.ID.allCases.filter { !claimed.contains($0) }
        #expect(unclaimed == [
            .retiredInstrumentVersion,
            .retiredLayoutTotalDuration,
            .retiredLayoutMaxDuration,
            .retiredSyncEventType,
            .retiredSyncSucceeded,
            .retiredChangedKeyCount,
        ])
    }

    @Test func valueScalarMatchesCase() {
        #expect(ComponentValue.string("x").scalar == .string)
        #expect(ComponentValue.float32(1).scalar == .float32)
        #expect(ComponentValue.uint64(1).scalar == .uint64)
        #expect(ComponentValue.bool(true).scalar == .bool)
    }

    /// A retired id is reserved, not deleted — reissuing it corrupts old artifacts.
    @Test func retiredIdsStayReserved() {
        #expect(Component.ID.retiredInstrumentVersion.rawValue == 16)
        #expect(Component.ID.retiredLayoutTotalDuration.rawValue == 21)
        #expect(Component.ID.retiredLayoutMaxDuration.rawValue == 22)
        #expect(Component.ID.retiredSyncEventType.rawValue == 166)
        #expect(Component.ID.retiredSyncSucceeded.rawValue == 167)
        #expect(Component.ID.retiredChangedKeyCount.rawValue == 169)
    }

    /// The unit lives in the component's name — off-wire, so free on the frame.
    @Test func everyMeasuredComponentNamesItsUnit() {
        let measured: [Component.ID] = [
            .memoryUsedBytes, .methodDurationMilliseconds, .totalNanoseconds,
            .peakNanoseconds, .passCount, .cpuUsageRatio, .hardwareCostRatio,
            .systemPressureCostRatio, .formatWidthPixels, .formatHeightPixels,
            .formatMinFramesPerSecond, .formatMaxFramesPerSecond,
            .videoRotationDegrees, .framesDeliveredCount, .framesDroppedCount,
            .inputCount, .outputCount, .connectionCount, .activeConnectionCount,
            .formatCount, .activeTouchCount, .touchesMovedCount,
            .dragDistancePoints, .maximumSimultaneousTouchCount,
        ]
        let units = [
            "Bytes", "Milliseconds", "Nanoseconds", "Count", "Ratio", "fps",
            "Pixels", "PerSecond", "Degrees", "Points",
        ]

        for id in measured {
            #expect(
                units.contains { "\(id)".localizedCaseInsensitiveContains($0) },
                "\(id) does not say what it is measured in"
            )
        }
    }

    /// A Float millisecond lost 119ns to rounding; nanoseconds from the clock fixed it.
    @Test func layoutDurationsAreIntegerNanoseconds() {
        #expect(Component.totalNanoseconds(12296).value == .uint64(12296))
        #expect(Component.peakNanoseconds(373667).value == .uint64(373667))
    }

    /// Value precedes id — otherwise Swift pads the id to align the 8-byte value.
    @Test func aComponentCostsNoPadding() {
        #expect(MemoryLayout<Component>.stride == 24)
        #expect(MemoryLayout<Component>.offset(of: \.value) == 0)
    }

    /// Exhaustive tables catch a missing label; this catches a blank or duplicate one.
    @Test func everyIdHasItsOwnLabel() {
        let labels = Component.ID.allCases.map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
    }
}
