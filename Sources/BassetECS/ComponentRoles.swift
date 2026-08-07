/// What a component's value *does*, as opposed to what type it is stored as.
///
/// A reader that decides how to draw a value from its scalar gets this wrong in
/// one specific and embarrassing way: a great many identifiers are integers. A
/// load address, a stack frame, a launch id and a thread index are all `UInt64`
/// or `UInt32`, and a view that plots every number it is given will draw a line
/// through two memory addresses and print the larger one as a peak. Nothing
/// about that is true — an address is not a quantity, and one address is not
/// more than another.
///
/// So the question is not "is this a number" but "does this measure something",
/// which the scalar cannot answer. A tagged scalar says how a value is stored;
/// this says what it means, and the two are not the same question.
///
/// The switch is exhaustive on purpose. Minting a component is a compile error
/// until somebody says which of these it is, which is the only way a default
/// cannot quietly be wrong — and the wrong default here is the expensive one,
/// because it invents a trend rather than omitting one.
public enum ComponentRole: Equatable, Sendable {
    /// A magnitude. Comparable, summable, worth a line and a peak.
    case quantity
    /// A value that changes and is worth seeing change, but has no size:
    /// strings, flags, codes, addresses, indices.
    case state
    /// An id that ties readings together rather than describing one. Every
    /// reading in a capture carries the same launch, so a row per group for it
    /// is the same fact drawn five times.
    case correlation
}

public extension Component.ID {
    var role: ComponentRole {
        switch self {
        case .activeConnectionCount,
             .bytesReceivedCount,
             .bytesSentCount,
             .callbackCount,
             .changedKeyCount,
             .connectionCount,
             .connectNanoseconds,
             .contentProcessTerminations,
             .cpuNanoseconds,
             .cpuUsageRatio,
             .deadlineMissCount,
             .deadlineOverrunNanoseconds,
             .deletedCount,
             .displayListChangeCount,
             .displayListItemCount,
             .dnsNanoseconds,
             .formatCount,
             .formatHeightPixels,
             .formatMaxFramesPerSecond,
             .formatMinFramesPerSecond,
             .formatWidthPixels,
             .fps,
             .framesDeliveredCount,
             .framesDroppedCount,
             .hangNanoseconds,
             .hardwareCostRatio,
             .hostAppearNanoseconds,
             .hostCount,
             .idleWakeupCount,
             .inputCount,
             .insertedCount,
             .mapLoadsCompleted,
             .maximumConnectionsPerHost,
             .memoryAvailableBytes,
             .memoryLimitBytes,
             .memoryUsedBytes,
             .methodDurationMilliseconds,
             .occurrenceCount,
             .outputCount,
             .outputVolume,
             .passCount,
             .peakNanoseconds,
             .presentationLatencyNanoseconds,
             .queueLatencyNanoseconds,
             .refreshedCount,
             .requestTimeoutSeconds,
             .resourceTimeoutSeconds,
             .responseNanoseconds,
             .retiredLayoutMaxDuration,
             .retiredLayoutTotalDuration,
             .runLoopTurnCount,
             .serverNanoseconds,
             .silenceNanoseconds,
             .systemPressureCostRatio,
             .tileLoadFailures,
             .tlsNanoseconds,
             .totalNanoseconds,
             .transactionCount,
             .updatedCount,
             .videoRotationDegrees,
             .wakeupCount,
             .windowNanoseconds:
            .quantity

        // A seed is opaque and its value means nothing, but it only ever grows,
        // and the rate it grows at is the whole signal `swiftui.displayList`
        // exists to report. Plotting it draws that slope; banding it would draw
        // a fresh band per reading and say nothing.
        case .displayListSeed:
            .quantity

        case .deviceId,
             .deviceUniqueId,
             .instanceId,
             .instrument,
             .launchId,
             .threadIdentifier,
             .userId:
            .correlation

        // Numbers that are not quantities. Two addresses have no order worth
        // drawing, a thread index says which thread and not how much, and an
        // error code is a name that happens to be spelled in digits.
        case .errorCode,
             .frameAddress,
             .httpStatusCode,
             .imageLoadAddress,
             .multiCamSetIndex,
             .retiredInstrumentVersion,
             .threadBasePriority,
             .threadIndex,
             .threadPriority:
            .state

        // A wall-clock instant, and the one number here that is stored as a
        // count of something. It orders readings and names the day a tally
        // covers; charted, it draws a line whose slope is the passage of time.
        case .intervalEndMicroseconds:
            .state

        case .accuracyClass,
             .activeColorSpace,
             .alertStyle,
             .appState,
             .appVersion,
             .audioCategory,
             .audioCategoryOptions,
             .audioInputPort,
             .audioMode,
             .audioOutputName,
             .audioOutputPort,
             .audioPreviousOutputPort,
             .audioRouteVerdict,
             .authorizationStatus,
             .bluetoothState,
             .buildConfiguration,
             .buildUUID,
             .bundleId,
             .cachePolicy,
             .calendarIdentifier,
             .callAction,
             .changeReason,
             .contextConcurrency,
             .delegateClass,
             .detail,
             .deviceKind,
             .deviceModel,
             .devicePosition,
             .deviceType,
             .dnsProtocol,
             .dropReason,
             .errorDomain,
             .exceptionDomain,
             .exitReason,
             .formatPixelFormat,
             .hostKind,
             .hostNavigationTitle,
             .hostRootViewType,
             .hostViewClass,
             .imageName,
             .imageUUID,
             .interfaceKind,
             .ivarPathGeneration,
             .languageCode,
             .layoutDirection,
             .logCategory,
             .logLevel,
             .logMessage,
             .logSubsystem,
             .mechanismStatus,
             .memoryPressureLevel,
             .memoryPressureScope,
             .methodName,
             .minimumTLSVersion,
             .multiCamSetMembers,
             .negotiatedProtocol,
             .notificationSetting,
             .osVersion,
             .outputPixelFormat,
             .permissionSubject,
             .presentationKind,
             .presentedRootViewType,
             .previewVisibility,
             .queueLabel,
             .regionCode,
             .remoteAddress,
             .requestURL,
             .serverVersion,
             .sessionClass,
             .sessionPreset,
             .settingName,
             .settingState,
             .source,
             .syncEventType,
             .systemPressureLevel,
             .textSizeCategory,
             .thermalState,
             .threadName,
             .threadRunState,
             .tlsCipherSuite,
             .tlsVersion,
             .unsatisfiedReason,
             .viewControllerClass:
            .state

        case .accessibilityTextSize,
             .allowsCellular,
             .allowsConstrained,
             .allowsExpensive,
             .arbitraryLoadsAllowed,
             .callbackImplemented,
             .confinementViolation,
             .connectionReused,
             .constrainedInterface,
             .expensiveInterface,
             .formatMultiCamSupported,
             .hangResolved,
             .hostRootViewOpaque,
             .insecureLoadsAllowed,
             .multipath,
             .otherAudioPlaying,
             .outputPixelFormatSupported,
             .pathSatisfied,
             .proxyConnection,
             .secondaryAudioSilenced,
             .sessionInterrupted,
             .sessionRunning,
             .settingEnabled,
             .syncSucceeded,
             .threadIdle,
             .threadIsMain,
             .usageDescriptionDeclared,
             .uses24HourTime,
             .usesMetricSystem,
             .videoMirrored,
             .waitsForConnectivity:
            .state
        }
    }
}
