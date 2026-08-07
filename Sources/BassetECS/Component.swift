import Foundation

public enum Scalar: UInt8, Sendable, CaseIterable {
    case int8 = 1
    case int16 = 2
    case int32 = 3
    case int64 = 4
    case uint8 = 5
    case uint16 = 6
    case uint32 = 7
    case uint64 = 8
    case float32 = 9
    case float64 = 10
    case string = 11
    case bool = 12
}

public protocol ScalarValue {
    var componentValue: ComponentValue { get }
}

// MARK: - Int8 + ScalarValue

extension Int8: ScalarValue { public var componentValue: ComponentValue {
    .int8(self)
} }

// MARK: - Int16 + ScalarValue

extension Int16: ScalarValue { public var componentValue: ComponentValue {
    .int16(self)
}
}

// MARK: - Int32 + ScalarValue

extension Int32: ScalarValue { public var componentValue: ComponentValue {
    .int32(self)
}
}

// MARK: - Int64 + ScalarValue

extension Int64: ScalarValue { public var componentValue: ComponentValue {
    .int64(self)
}
}

// MARK: - UInt8 + ScalarValue

extension UInt8: ScalarValue { public var componentValue: ComponentValue {
    .uint8(self)
}
}

// MARK: - UInt16 + ScalarValue

extension UInt16: ScalarValue {
    public var componentValue: ComponentValue {
        .uint16(self)
    }
}

// MARK: - UInt32 + ScalarValue

extension UInt32: ScalarValue {
    public var componentValue: ComponentValue {
        .uint32(self)
    }
}

// MARK: - UInt64 + ScalarValue

extension UInt64: ScalarValue {
    public var componentValue: ComponentValue {
        .uint64(self)
    }
}

// MARK: - Float + ScalarValue

extension Float: ScalarValue {
    public var componentValue: ComponentValue {
        .float32(self)
    }
}

// MARK: - Double + ScalarValue

extension Double: ScalarValue {
    public var componentValue: ComponentValue {
        .float64(self)
    }
}

// MARK: - String + ScalarValue

extension String: ScalarValue {
    public var componentValue: ComponentValue {
        .string(self)
    }
}

// MARK: - Bool + ScalarValue

extension Bool: ScalarValue { public var componentValue: ComponentValue {
    .bool(self)
} }

public enum ComponentValue: Equatable, Sendable {
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    case float32(Float)
    case float64(Double)
    case string(String)
    case bool(Bool)

    public var scalar: Scalar {
        switch self {
        case .int8: .int8
        case .int16: .int16
        case .int32: .int32
        case .int64: .int64
        case .uint8: .uint8
        case .uint16: .uint16
        case .uint32: .uint32
        case .uint64: .uint64
        case .float32: .float32
        case .float64: .float64
        case .string: .string
        case .bool: .bool
        }
    }

    public var rendered: String {
        switch self {
        case .int8(let value): "\(value)"
        case .int16(let value): "\(value)"
        case .int32(let value): "\(value)"
        case .int64(let value): "\(value)"
        case .uint8(let value): "\(value)"
        case .uint16(let value): "\(value)"
        case .uint32(let value): "\(value)"
        case .uint64(let value): "\(value)"
        case .float32(let value): "\(value)"
        case .float64(let value): "\(value)"
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        }
    }
}

public enum Component: Equatable, Sendable {
    case cpuUsageRatio(Float)
    case fps(Float)
    case deviceId(String)
    case source(String)
    case methodName(String)
    case methodDurationMilliseconds(Float)
    case deviceModel(String)
    case osVersion(String)
    case appVersion(String)
    case userId(String)
    case serverVersion(String)
    case memoryUsedBytes(UInt64)
    case thermalState(String)
    case detail(String)
    case instrument(UInt16)
    case bundleId(String)
    case buildConfiguration(String)
    case deviceKind(String)
    case passCount(UInt64)
    case totalNanoseconds(UInt64)
    case peakNanoseconds(UInt64)
    case sessionRunning(Bool)
    case sessionInterrupted(Bool)
    case viewControllerClass(String)
    case instanceId(UInt32)
    case httpStatusCode(Int32)
    case negotiatedProtocol(String)
    case bytesSentCount(UInt64)
    case bytesReceivedCount(UInt64)
    case requestURL(String)
    case connectionReused(Bool)
    case interfaceKind(String)
    case pathSatisfied(Bool)
    case expensiveInterface(Bool)
    case constrainedInterface(Bool)
    case unsatisfiedReason(String)
    case errorDomain(String)
    case errorCode(Int32)
    case appState(String)
    case sessionClass(String)
    case sessionPreset(String)
    case inputCount(UInt32)
    case outputCount(UInt32)
    case connectionCount(UInt32)
    case activeConnectionCount(UInt32)
    case hardwareCostRatio(Float)
    case systemPressureCostRatio(Float)
    case systemPressureLevel(String)
    case deviceType(String)
    case devicePosition(String)
    case deviceUniqueId(String)
    case formatWidthPixels(Int32)
    case formatHeightPixels(Int32)
    case formatPixelFormat(String)
    case formatMinFramesPerSecond(Float)
    case formatMaxFramesPerSecond(Float)
    case formatMultiCamSupported(Bool)
    case formatCount(UInt32)
    case activeColorSpace(String)
    case videoRotationDegrees(Float)
    case videoMirrored(Bool)
    case multiCamSetIndex(UInt32)
    case multiCamSetMembers(String)
    case outputPixelFormat(String)
    case outputPixelFormatSupported(Bool)
    case framesDeliveredCount(UInt64)
    case framesDroppedCount(UInt64)
    case dropReason(String)
    case hangNanoseconds(UInt64)
    case hangResolved(Bool)
    case runLoopTurnCount(UInt64)
    case threadIndex(UInt32)
    case threadName(String)
    case threadIsMain(Bool)
    case frameAddress(UInt64)
    case imageName(String)
    case imageLoadAddress(UInt64)
    case imageUUID(String)
    case buildUUID(String)
    case launchId(UInt64)
    case logSubsystem(String)
    case logCategory(String)
    case logMessage(String)
    case occurrenceCount(UInt64)
    case hostRootViewType(String)
    case hostRootViewOpaque(Bool)
    case hostNavigationTitle(String)
    case hostAppearNanoseconds(UInt64)
    case hostKind(String)
    case hostCount(UInt32)
    case hostViewClass(String)
    case mechanismStatus(String)
    case displayListSeed(UInt32)
    case displayListItemCount(UInt32)
    case displayListChangeCount(UInt64)
    case ivarPathGeneration(String)
    case presentationKind(String)
    case presentedRootViewType(String)
    case windowNanoseconds(UInt64)
    case memoryLimitBytes(UInt64)
    case memoryAvailableBytes(UInt64)
    case memoryPressureLevel(String)
    case memoryPressureScope(String)
    case exitReason(String)
    case intervalEndMicroseconds(UInt64)
    case permissionSubject(String)
    case authorizationStatus(String)
    case usageDescriptionDeclared(Bool)
    case threadIdentifier(UInt64)
    case threadRunState(String)
    case threadIdle(Bool)
    case threadPriority(Int32)
    case threadBasePriority(Int32)
    case cpuNanoseconds(UInt64)
    case wakeupCount(UInt64)
    case idleWakeupCount(UInt64)
    case queueLatencyNanoseconds(UInt64)
    case queueLabel(String)
    case insertedCount(UInt32)
    case updatedCount(UInt32)
    case deletedCount(UInt32)
    case refreshedCount(UInt32)
    case contextConcurrency(String)
    case confinementViolation(Bool)
    case logLevel(String)
    case dnsNanoseconds(UInt64)
    case connectNanoseconds(UInt64)
    case tlsNanoseconds(UInt64)
    case serverNanoseconds(UInt64)
    case responseNanoseconds(UInt64)
    case tlsVersion(String)
    case tlsCipherSuite(String)
    case transactionCount(UInt32)
    case requestTimeoutSeconds(Float)
    case resourceTimeoutSeconds(Float)
    case allowsCellular(Bool)
    case allowsExpensive(Bool)
    case allowsConstrained(Bool)
    case waitsForConnectivity(Bool)
    case maximumConnectionsPerHost(UInt32)
    case cachePolicy(String)
    case dnsProtocol(String)
    case remoteAddress(String)
    case proxyConnection(Bool)
    case multipath(Bool)
    case arbitraryLoadsAllowed(Bool)
    case exceptionDomain(String)
    case insecureLoadsAllowed(Bool)
    case minimumTLSVersion(String)
    case deadlineMissCount(UInt32)
    case deadlineOverrunNanoseconds(UInt64)
    case presentationLatencyNanoseconds(UInt64)
    case settingName(String)
    case settingEnabled(Bool)
    case textSizeCategory(String)
    case accessibilityTextSize(Bool)
    case languageCode(String)
    case regionCode(String)
    case calendarIdentifier(String)
    case usesMetricSystem(Bool)
    case uses24HourTime(Bool)
    case layoutDirection(String)
    case syncEventType(String)
    case syncSucceeded(Bool)
    case changeReason(String)
    case changedKeyCount(UInt32)
    case notificationSetting(String)
    case settingState(String)
    case alertStyle(String)
    case previewVisibility(String)
    case callbackImplemented(Bool)
    case silenceNanoseconds(UInt64)
    case accuracyClass(String)
    case callbackCount(UInt64)
    case delegateClass(String)
    case bluetoothState(String)
    case contentProcessTerminations(UInt64)
    case tileLoadFailures(UInt64)
    case mapLoadsCompleted(UInt64)
    case callAction(String)
    case audioOutputPort(String)
    case audioOutputName(String)
    case audioInputPort(String)
    case audioCategory(String)
    case audioMode(String)
    case audioCategoryOptions(String)
    case audioPreviousOutputPort(String)
    case audioRouteVerdict(String)
    case outputVolume(Float)
    case otherAudioPlaying(Bool)
    case secondaryAudioSilenced(Bool)

    public enum ID: UInt16, Sendable, CaseIterable {
        case cpuUsageRatio = 1
        case fps = 2
        case deviceId = 3
        case source = 4
        case methodName = 5
        case methodDurationMilliseconds = 6
        case deviceModel = 7
        case osVersion = 8
        case appVersion = 9
        case userId = 10
        case serverVersion = 11
        case memoryUsedBytes = 12
        case thermalState = 13
        case detail = 14
        case instrument = 15
        case retiredInstrumentVersion = 16
        case bundleId = 17
        case buildConfiguration = 18
        case deviceKind = 19
        case passCount = 20
        case retiredLayoutTotalDuration = 21
        case retiredLayoutMaxDuration = 22
        case sessionRunning = 23
        case sessionInterrupted = 24
        case viewControllerClass = 25
        case totalNanoseconds = 26
        case peakNanoseconds = 27
        case instanceId = 28
        case httpStatusCode = 29
        case negotiatedProtocol = 30
        case bytesSentCount = 31
        case bytesReceivedCount = 32
        case requestURL = 33
        case connectionReused = 34
        case interfaceKind = 35
        case pathSatisfied = 36
        case expensiveInterface = 37
        case constrainedInterface = 38
        case unsatisfiedReason = 39
        case errorDomain = 40
        case errorCode = 41
        case appState = 42
        case sessionClass = 43
        case sessionPreset = 44
        case inputCount = 45
        case outputCount = 46
        case connectionCount = 47
        case activeConnectionCount = 48
        case hardwareCostRatio = 49
        case systemPressureCostRatio = 50
        case systemPressureLevel = 51
        case deviceType = 52
        case devicePosition = 53
        case deviceUniqueId = 54
        case formatWidthPixels = 55
        case formatHeightPixels = 56
        case formatPixelFormat = 57
        case formatMinFramesPerSecond = 58
        case formatMaxFramesPerSecond = 59
        case formatMultiCamSupported = 60
        case formatCount = 61
        case activeColorSpace = 62
        case videoRotationDegrees = 63
        case videoMirrored = 64
        case multiCamSetIndex = 65
        case multiCamSetMembers = 66
        case outputPixelFormat = 67
        case outputPixelFormatSupported = 68
        case framesDeliveredCount = 69
        case framesDroppedCount = 70
        case dropReason = 71
        case hangNanoseconds = 72
        case hangResolved = 73
        case runLoopTurnCount = 74
        case threadIndex = 75
        case threadName = 76
        case threadIsMain = 77
        case frameAddress = 78
        case imageName = 79
        case imageLoadAddress = 80
        case imageUUID = 81
        case buildUUID = 82
        case launchId = 83
        case logSubsystem = 84
        case logCategory = 85
        case logMessage = 86
        case occurrenceCount = 87
        case hostRootViewType = 88
        case hostRootViewOpaque = 89
        case hostNavigationTitle = 90
        case hostAppearNanoseconds = 91
        case hostKind = 92
        case hostCount = 93
        case hostViewClass = 94
        case mechanismStatus = 95
        case displayListSeed = 96
        case displayListItemCount = 97
        case displayListChangeCount = 98
        case ivarPathGeneration = 99
        case presentationKind = 100
        case presentedRootViewType = 101
        case windowNanoseconds = 102
        case memoryLimitBytes = 103
        case memoryAvailableBytes = 104
        case memoryPressureLevel = 105
        case memoryPressureScope = 106
        case exitReason = 107
        case intervalEndMicroseconds = 108
        case permissionSubject = 109
        case authorizationStatus = 110
        case usageDescriptionDeclared = 111
        case threadIdentifier = 112
        case threadRunState = 113
        case threadIdle = 114
        case threadPriority = 115
        case threadBasePriority = 116
        case cpuNanoseconds = 117
        case wakeupCount = 118
        case idleWakeupCount = 119
        case queueLatencyNanoseconds = 120
        case queueLabel = 121
        case insertedCount = 122
        case updatedCount = 123
        case deletedCount = 124
        case refreshedCount = 125
        case contextConcurrency = 126
        case confinementViolation = 127
        case logLevel = 128
        case dnsNanoseconds = 129
        case connectNanoseconds = 130
        case tlsNanoseconds = 131
        case serverNanoseconds = 132
        case responseNanoseconds = 133
        case tlsVersion = 134
        case tlsCipherSuite = 135
        case transactionCount = 136
        case requestTimeoutSeconds = 137
        case resourceTimeoutSeconds = 138
        case allowsCellular = 139
        case allowsExpensive = 140
        case allowsConstrained = 141
        case waitsForConnectivity = 142
        case maximumConnectionsPerHost = 143
        case cachePolicy = 144
        case dnsProtocol = 145
        case remoteAddress = 146
        case proxyConnection = 147
        case multipath = 148
        case arbitraryLoadsAllowed = 149
        case exceptionDomain = 150
        case insecureLoadsAllowed = 151
        case minimumTLSVersion = 152
        case deadlineMissCount = 153
        case deadlineOverrunNanoseconds = 154
        case presentationLatencyNanoseconds = 155
        case settingName = 156
        case settingEnabled = 157
        case textSizeCategory = 158
        case accessibilityTextSize = 159
        case languageCode = 160
        case regionCode = 161
        case calendarIdentifier = 162
        case usesMetricSystem = 163
        case uses24HourTime = 164
        case layoutDirection = 165
        case syncEventType = 166
        case syncSucceeded = 167
        case changeReason = 168
        case changedKeyCount = 169
        case notificationSetting = 170
        case settingState = 171
        case alertStyle = 172
        case previewVisibility = 173
        case callbackImplemented = 174
        case silenceNanoseconds = 175
        case accuracyClass = 176
        case callbackCount = 177
        case delegateClass = 178
        case bluetoothState = 179
        case contentProcessTerminations = 180
        case tileLoadFailures = 181
        case mapLoadsCompleted = 182
        case callAction = 183
        case audioOutputPort = 184
        case audioOutputName = 185
        case audioInputPort = 186
        case audioCategory = 187
        case audioMode = 188
        case audioCategoryOptions = 189
        case audioPreviousOutputPort = 190
        case audioRouteVerdict = 191
        case outputVolume = 192
        case otherAudioPlaying = 193
        case secondaryAudioSilenced = 194
    }

    public var wire: (id: ID, value: ComponentValue) {
        switch self {
        case .cpuUsageRatio(let v): (.cpuUsageRatio, v.componentValue)
        case .fps(let v): (.fps, v.componentValue)
        case .deviceId(let v): (.deviceId, v.componentValue)
        case .source(let v): (.source, v.componentValue)
        case .methodName(let v): (.methodName, v.componentValue)
        case .methodDurationMilliseconds(let v): (
                .methodDurationMilliseconds,
                v.componentValue
            )
        case .deviceModel(let v): (.deviceModel, v.componentValue)
        case .osVersion(let v): (.osVersion, v.componentValue)
        case .appVersion(let v): (.appVersion, v.componentValue)
        case .userId(let v): (.userId, v.componentValue)
        case .serverVersion(let v): (.serverVersion, v.componentValue)
        case .memoryUsedBytes(let v): (.memoryUsedBytes, v.componentValue)
        case .thermalState(let v): (.thermalState, v.componentValue)
        case .detail(let v): (.detail, v.componentValue)
        case .instrument(let v): (.instrument, v.componentValue)
        case .bundleId(let v): (.bundleId, v.componentValue)
        case .buildConfiguration(let v): (.buildConfiguration, v.componentValue)
        case .deviceKind(let v): (.deviceKind, v.componentValue)
        case .passCount(let v): (.passCount, v.componentValue)
        case .totalNanoseconds(let v): (.totalNanoseconds, v.componentValue)
        case .peakNanoseconds(let v): (.peakNanoseconds, v.componentValue)
        case .sessionRunning(let v): (.sessionRunning, v.componentValue)
        case .sessionInterrupted(let v): (.sessionInterrupted, v.componentValue)
        case .viewControllerClass(let v): (.viewControllerClass, v.componentValue)
        case .instanceId(let v): (.instanceId, v.componentValue)
        case .httpStatusCode(let v): (.httpStatusCode, v.componentValue)
        case .negotiatedProtocol(let v): (.negotiatedProtocol, v.componentValue)
        case .bytesSentCount(let v): (.bytesSentCount, v.componentValue)
        case .bytesReceivedCount(let v): (.bytesReceivedCount, v.componentValue)
        case .requestURL(let v): (.requestURL, v.componentValue)
        case .connectionReused(let v): (.connectionReused, v.componentValue)
        case .interfaceKind(let v): (.interfaceKind, v.componentValue)
        case .pathSatisfied(let v): (.pathSatisfied, v.componentValue)
        case .expensiveInterface(let v): (.expensiveInterface, v.componentValue)
        case .constrainedInterface(let v): (.constrainedInterface, v.componentValue)
        case .unsatisfiedReason(let v): (.unsatisfiedReason, v.componentValue)
        case .errorDomain(let v): (.errorDomain, v.componentValue)
        case .errorCode(let v): (.errorCode, v.componentValue)
        case .appState(let v): (.appState, v.componentValue)
        case .sessionClass(let v): (.sessionClass, v.componentValue)
        case .sessionPreset(let v): (.sessionPreset, v.componentValue)
        case .inputCount(let v): (.inputCount, v.componentValue)
        case .outputCount(let v): (.outputCount, v.componentValue)
        case .connectionCount(let v): (.connectionCount, v.componentValue)
        case .activeConnectionCount(let v): (.activeConnectionCount, v.componentValue)
        case .hardwareCostRatio(let v): (.hardwareCostRatio, v.componentValue)
        case .systemPressureCostRatio(let v): (.systemPressureCostRatio, v.componentValue)
        case .systemPressureLevel(let v): (.systemPressureLevel, v.componentValue)
        case .deviceType(let v): (.deviceType, v.componentValue)
        case .devicePosition(let v): (.devicePosition, v.componentValue)
        case .deviceUniqueId(let v): (.deviceUniqueId, v.componentValue)
        case .formatWidthPixels(let v): (.formatWidthPixels, v.componentValue)
        case .formatHeightPixels(let v): (.formatHeightPixels, v.componentValue)
        case .formatPixelFormat(let v): (.formatPixelFormat, v.componentValue)
        case .formatMinFramesPerSecond(let v): (
                .formatMinFramesPerSecond,
                v.componentValue
            )
        case .formatMaxFramesPerSecond(let v): (
                .formatMaxFramesPerSecond,
                v.componentValue
            )
        case .formatMultiCamSupported(let v): (.formatMultiCamSupported, v.componentValue)
        case .formatCount(let v): (.formatCount, v.componentValue)
        case .activeColorSpace(let v): (.activeColorSpace, v.componentValue)
        case .videoRotationDegrees(let v): (.videoRotationDegrees, v.componentValue)
        case .videoMirrored(let v): (.videoMirrored, v.componentValue)
        case .multiCamSetIndex(let v): (.multiCamSetIndex, v.componentValue)
        case .multiCamSetMembers(let v): (.multiCamSetMembers, v.componentValue)
        case .outputPixelFormat(let v): (.outputPixelFormat, v.componentValue)
        case .outputPixelFormatSupported(let v): (
                .outputPixelFormatSupported,
                v.componentValue
            )
        case .framesDeliveredCount(let v): (.framesDeliveredCount, v.componentValue)
        case .framesDroppedCount(let v): (.framesDroppedCount, v.componentValue)
        case .dropReason(let v): (.dropReason, v.componentValue)
        case .hangNanoseconds(let v): (.hangNanoseconds, v.componentValue)
        case .hangResolved(let v): (.hangResolved, v.componentValue)
        case .runLoopTurnCount(let v): (.runLoopTurnCount, v.componentValue)
        case .threadIndex(let v): (.threadIndex, v.componentValue)
        case .threadName(let v): (.threadName, v.componentValue)
        case .threadIsMain(let v): (.threadIsMain, v.componentValue)
        case .frameAddress(let v): (.frameAddress, v.componentValue)
        case .imageName(let v): (.imageName, v.componentValue)
        case .imageLoadAddress(let v): (.imageLoadAddress, v.componentValue)
        case .imageUUID(let v): (.imageUUID, v.componentValue)
        case .buildUUID(let v): (.buildUUID, v.componentValue)
        case .launchId(let v): (.launchId, v.componentValue)
        case .logSubsystem(let v): (.logSubsystem, v.componentValue)
        case .logCategory(let v): (.logCategory, v.componentValue)
        case .logMessage(let v): (.logMessage, v.componentValue)
        case .occurrenceCount(let v): (.occurrenceCount, v.componentValue)
        case .hostRootViewType(let v): (.hostRootViewType, v.componentValue)
        case .hostRootViewOpaque(let v): (.hostRootViewOpaque, v.componentValue)
        case .hostNavigationTitle(let v): (.hostNavigationTitle, v.componentValue)
        case .hostAppearNanoseconds(let v): (.hostAppearNanoseconds, v.componentValue)
        case .hostKind(let v): (.hostKind, v.componentValue)
        case .hostCount(let v): (.hostCount, v.componentValue)
        case .hostViewClass(let v): (.hostViewClass, v.componentValue)
        case .mechanismStatus(let v): (.mechanismStatus, v.componentValue)
        case .displayListSeed(let v): (.displayListSeed, v.componentValue)
        case .displayListItemCount(let v): (.displayListItemCount, v.componentValue)
        case .displayListChangeCount(let v): (.displayListChangeCount, v.componentValue)
        case .ivarPathGeneration(let v): (.ivarPathGeneration, v.componentValue)
        case .presentationKind(let v): (.presentationKind, v.componentValue)
        case .presentedRootViewType(let v): (.presentedRootViewType, v.componentValue)
        case .windowNanoseconds(let v): (.windowNanoseconds, v.componentValue)
        case .memoryLimitBytes(let v): (.memoryLimitBytes, v.componentValue)
        case .memoryAvailableBytes(let v): (.memoryAvailableBytes, v.componentValue)
        case .memoryPressureLevel(let v): (.memoryPressureLevel, v.componentValue)
        case .memoryPressureScope(let v): (.memoryPressureScope, v.componentValue)
        case .exitReason(let v): (.exitReason, v.componentValue)
        case .intervalEndMicroseconds(let v): (.intervalEndMicroseconds, v.componentValue)
        case .permissionSubject(let v): (.permissionSubject, v.componentValue)
        case .authorizationStatus(let v): (.authorizationStatus, v.componentValue)
        case .usageDescriptionDeclared(let v): (
                .usageDescriptionDeclared,
                v.componentValue
            )
        case .threadIdentifier(let v): (.threadIdentifier, v.componentValue)
        case .threadRunState(let v): (.threadRunState, v.componentValue)
        case .threadIdle(let v): (.threadIdle, v.componentValue)
        case .threadPriority(let v): (.threadPriority, v.componentValue)
        case .threadBasePriority(let v): (.threadBasePriority, v.componentValue)
        case .cpuNanoseconds(let v): (.cpuNanoseconds, v.componentValue)
        case .wakeupCount(let v): (.wakeupCount, v.componentValue)
        case .idleWakeupCount(let v): (.idleWakeupCount, v.componentValue)
        case .queueLatencyNanoseconds(let v): (.queueLatencyNanoseconds, v.componentValue)
        case .queueLabel(let v): (.queueLabel, v.componentValue)
        case .insertedCount(let v): (.insertedCount, v.componentValue)
        case .updatedCount(let v): (.updatedCount, v.componentValue)
        case .deletedCount(let v): (.deletedCount, v.componentValue)
        case .refreshedCount(let v): (.refreshedCount, v.componentValue)
        case .contextConcurrency(let v): (.contextConcurrency, v.componentValue)
        case .confinementViolation(let v): (.confinementViolation, v.componentValue)
        case .logLevel(let v): (.logLevel, v.componentValue)
        case .dnsNanoseconds(let v): (.dnsNanoseconds, v.componentValue)
        case .connectNanoseconds(let v): (.connectNanoseconds, v.componentValue)
        case .tlsNanoseconds(let v): (.tlsNanoseconds, v.componentValue)
        case .serverNanoseconds(let v): (.serverNanoseconds, v.componentValue)
        case .responseNanoseconds(let v): (.responseNanoseconds, v.componentValue)
        case .tlsVersion(let v): (.tlsVersion, v.componentValue)
        case .tlsCipherSuite(let v): (.tlsCipherSuite, v.componentValue)
        case .transactionCount(let v): (.transactionCount, v.componentValue)
        case .requestTimeoutSeconds(let v): (.requestTimeoutSeconds, v.componentValue)
        case .resourceTimeoutSeconds(let v): (.resourceTimeoutSeconds, v.componentValue)
        case .allowsCellular(let v): (.allowsCellular, v.componentValue)
        case .allowsExpensive(let v): (.allowsExpensive, v.componentValue)
        case .allowsConstrained(let v): (.allowsConstrained, v.componentValue)
        case .waitsForConnectivity(let v): (.waitsForConnectivity, v.componentValue)
        case .maximumConnectionsPerHost(let v): (
                .maximumConnectionsPerHost,
                v.componentValue
            )
        case .cachePolicy(let v): (.cachePolicy, v.componentValue)
        case .dnsProtocol(let v): (.dnsProtocol, v.componentValue)
        case .remoteAddress(let v): (.remoteAddress, v.componentValue)
        case .proxyConnection(let v): (.proxyConnection, v.componentValue)
        case .multipath(let v): (.multipath, v.componentValue)
        case .arbitraryLoadsAllowed(let v): (.arbitraryLoadsAllowed, v.componentValue)
        case .exceptionDomain(let v): (.exceptionDomain, v.componentValue)
        case .insecureLoadsAllowed(let v): (.insecureLoadsAllowed, v.componentValue)
        case .minimumTLSVersion(let v): (.minimumTLSVersion, v.componentValue)
        case .deadlineMissCount(let v): (.deadlineMissCount, v.componentValue)
        case .deadlineOverrunNanoseconds(let v): (
                .deadlineOverrunNanoseconds,
                v.componentValue
            )
        case .presentationLatencyNanoseconds(let v): (
                .presentationLatencyNanoseconds,
                v.componentValue
            )
        case .settingName(let v): (.settingName, v.componentValue)
        case .settingEnabled(let v): (.settingEnabled, v.componentValue)
        case .textSizeCategory(let v): (.textSizeCategory, v.componentValue)
        case .accessibilityTextSize(let v): (.accessibilityTextSize, v.componentValue)
        case .languageCode(let v): (.languageCode, v.componentValue)
        case .regionCode(let v): (.regionCode, v.componentValue)
        case .calendarIdentifier(let v): (.calendarIdentifier, v.componentValue)
        case .usesMetricSystem(let v): (.usesMetricSystem, v.componentValue)
        case .uses24HourTime(let v): (.uses24HourTime, v.componentValue)
        case .layoutDirection(let v): (.layoutDirection, v.componentValue)
        case .syncEventType(let v): (.syncEventType, v.componentValue)
        case .syncSucceeded(let v): (.syncSucceeded, v.componentValue)
        case .changeReason(let v): (.changeReason, v.componentValue)
        case .changedKeyCount(let v): (.changedKeyCount, v.componentValue)
        case .notificationSetting(let v): (.notificationSetting, v.componentValue)
        case .settingState(let v): (.settingState, v.componentValue)
        case .alertStyle(let v): (.alertStyle, v.componentValue)
        case .previewVisibility(let v): (.previewVisibility, v.componentValue)
        case .callbackImplemented(let v): (.callbackImplemented, v.componentValue)
        case .silenceNanoseconds(let v): (.silenceNanoseconds, v.componentValue)
        case .accuracyClass(let v): (.accuracyClass, v.componentValue)
        case .callbackCount(let v): (.callbackCount, v.componentValue)
        case .delegateClass(let v): (.delegateClass, v.componentValue)
        case .bluetoothState(let v): (.bluetoothState, v.componentValue)
        case .contentProcessTerminations(let v): (
                .contentProcessTerminations,
                v.componentValue
            )
        case .tileLoadFailures(let v): (.tileLoadFailures, v.componentValue)
        case .mapLoadsCompleted(let v): (.mapLoadsCompleted, v.componentValue)
        case .callAction(let v): (.callAction, v.componentValue)
        case .audioOutputPort(let v): (.audioOutputPort, v.componentValue)
        case .audioOutputName(let v): (.audioOutputName, v.componentValue)
        case .audioInputPort(let v): (.audioInputPort, v.componentValue)
        case .audioCategory(let v): (.audioCategory, v.componentValue)
        case .audioMode(let v): (.audioMode, v.componentValue)
        case .audioCategoryOptions(let v): (.audioCategoryOptions, v.componentValue)
        case .audioPreviousOutputPort(let v): (
                .audioPreviousOutputPort,
                v.componentValue
            )
        case .audioRouteVerdict(let v): (.audioRouteVerdict, v.componentValue)
        case .outputVolume(let v): (.outputVolume, v.componentValue)
        case .otherAudioPlaying(let v): (.otherAudioPlaying, v.componentValue)
        case .secondaryAudioSilenced(let v): (.secondaryAudioSilenced, v.componentValue)
        }
    }

    public var id: ID {
        wire.id
    }

    public var value: ComponentValue {
        wire.value
    }
}
