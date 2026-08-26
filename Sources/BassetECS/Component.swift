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

/// A reading's smallest unit. Built only through the factories below, pairing id and type.
public struct Component: Equatable, Sendable {
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
        case retiredSyncEventType = 166
        case retiredSyncSucceeded = 167
        case changeReason = 168
        case retiredChangedKeyCount = 169
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
        case sampleCount = 195
        case unwindFailureCount = 196
        case drawableRequestCount = 197
        case drawableSkippedCount = 198
        case drawableUnavailableCount = 199
        case gpuWaitNanoseconds = 200
        case gpuWaitPeakNanoseconds = 201
        case gpuExecutionNanoseconds = 202
        case gpuExecutionPeakNanoseconds = 203
        case frameBudgetNanoseconds = 204
        case overBudgetCount = 205
        case imageTextBytes = 206
        case bundledImageCount = 207
        case methodClass = 208
        case ownedByDeclaringImage = 209
        case implementationInMappedImage = 210
        case threadRequestedQos = 211
        case touchPhase = 212
        case activeTouchCount = 213
        case touchesMovedCount = 214
        case dragDistancePoints = 215
        case maximumSimultaneousTouchCount = 216
        case audioInputName = 217
        case audioInputDataSource = 218
        case audioInputPolarPattern = 219
        case audioInputOrientation = 220
        case audioInputVerdict = 221
        case audioInputAvailable = 222
        case audioPreferredInputHonored = 223
        case availableInputCount = 224
        case audioOutputCount = 225
        case delegateDurationNanoseconds = 226
        case delegateDurationPeakNanoseconds = 227
        case sdkVersion = 228
        case touchId = 229
        case originXPoints = 230
        case originYPoints = 231
        case frameWidthPoints = 232
        case frameHeightPoints = 233
        case runtimeClassName = 234
        case gestureRecognizerState = 235
        case viewId = 236
        case viewParent = 237
        case nestedLevel = 238
        case faultId = 239
        case renderDestination = 240
        case textureBackedImageCount = 241
        case emptyResultCount = 242
        case debuggerAttached = 243
        case interfaceOrientation = 244
        case activeInstrument = 245
    }

    // Order is load-bearing: value before id avoids padding out to a wider stride.
    public let value: ComponentValue
    public let id: ID

    private init(_ id: ID, _ value: some ScalarValue) {
        self.id = id
        self.value = value.componentValue
    }
}

public extension Component {
    static func cpuUsageRatio(_ value: Float) -> Component { .init(.cpuUsageRatio, value) }
    static func fps(_ value: Float) -> Component { .init(.fps, value) }
    static func deviceId(_ value: String) -> Component { .init(.deviceId, value) }
    static func source(_ value: String) -> Component { .init(.source, value) }
    static func methodName(_ value: String) -> Component { .init(.methodName, value) }
    static func methodDurationMilliseconds(_ value: Float) -> Component { .init(
        .methodDurationMilliseconds,
        value
    ) }
    static func deviceModel(_ value: String) -> Component { .init(.deviceModel, value) }
    static func osVersion(_ value: String) -> Component { .init(.osVersion, value) }
    static func appVersion(_ value: String) -> Component { .init(.appVersion, value) }
    static func userId(_ value: String) -> Component { .init(.userId, value) }
    static func serverVersion(_ value: String) -> Component { .init(.serverVersion, value) }
    static func memoryUsedBytes(_ value: UInt64) -> Component { .init(.memoryUsedBytes, value) }
    static func thermalState(_ value: String) -> Component { .init(.thermalState, value) }
    static func detail(_ value: String) -> Component { .init(.detail, value) }
    static func instrument(_ value: UInt16) -> Component { .init(.instrument, value) }
    static func bundleId(_ value: String) -> Component { .init(.bundleId, value) }
    static func buildConfiguration(_ value: String)
        -> Component { .init(.buildConfiguration, value) }
    static func deviceKind(_ value: String) -> Component { .init(.deviceKind, value) }
    static func sdkVersion(_ value: String) -> Component { .init(.sdkVersion, value) }
    static func passCount(_ value: UInt64) -> Component { .init(.passCount, value) }
    static func totalNanoseconds(_ value: UInt64) -> Component { .init(.totalNanoseconds, value) }
    static func peakNanoseconds(_ value: UInt64) -> Component { .init(.peakNanoseconds, value) }
    static func sessionRunning(_ value: Bool) -> Component { .init(.sessionRunning, value) }
    static func sessionInterrupted(_ value: Bool) -> Component { .init(.sessionInterrupted, value) }
    static func viewControllerClass(_ value: String) -> Component { .init(
        .viewControllerClass,
        value
    ) }
    static func instanceId(_ value: UInt32) -> Component { .init(.instanceId, value) }
    static func httpStatusCode(_ value: Int32) -> Component { .init(.httpStatusCode, value) }
    static func negotiatedProtocol(_ value: String)
        -> Component { .init(.negotiatedProtocol, value) }
    static func bytesSentCount(_ value: UInt64) -> Component { .init(.bytesSentCount, value) }
    static func bytesReceivedCount(_ value: UInt64)
        -> Component { .init(.bytesReceivedCount, value) }
    static func requestURL(_ value: String) -> Component { .init(.requestURL, value) }
    static func connectionReused(_ value: Bool) -> Component { .init(.connectionReused, value) }
    static func interfaceKind(_ value: String) -> Component { .init(.interfaceKind, value) }
    static func pathSatisfied(_ value: Bool) -> Component { .init(.pathSatisfied, value) }
    static func expensiveInterface(_ value: Bool) -> Component { .init(.expensiveInterface, value) }
    static func constrainedInterface(_ value: Bool) -> Component { .init(
        .constrainedInterface,
        value
    ) }
    static func unsatisfiedReason(_ value: String) -> Component { .init(.unsatisfiedReason, value) }
    static func errorDomain(_ value: String) -> Component { .init(.errorDomain, value) }
    static func errorCode(_ value: Int32) -> Component { .init(.errorCode, value) }
    static func appState(_ value: String) -> Component { .init(.appState, value) }
    static func sessionClass(_ value: String) -> Component { .init(.sessionClass, value) }
    static func sessionPreset(_ value: String) -> Component { .init(.sessionPreset, value) }
    static func inputCount(_ value: UInt32) -> Component { .init(.inputCount, value) }
    static func outputCount(_ value: UInt32) -> Component { .init(.outputCount, value) }
    static func connectionCount(_ value: UInt32) -> Component { .init(.connectionCount, value) }
    static func activeConnectionCount(_ value: UInt32) -> Component { .init(
        .activeConnectionCount,
        value
    ) }
    static func hardwareCostRatio(_ value: Float) -> Component { .init(.hardwareCostRatio, value) }
    static func systemPressureCostRatio(_ value: Float) -> Component { .init(
        .systemPressureCostRatio,
        value
    ) }
    static func systemPressureLevel(_ value: String) -> Component { .init(
        .systemPressureLevel,
        value
    ) }
    static func deviceType(_ value: String) -> Component { .init(.deviceType, value) }
    static func devicePosition(_ value: String) -> Component { .init(.devicePosition, value) }
    static func deviceUniqueId(_ value: String) -> Component { .init(.deviceUniqueId, value) }
    static func formatWidthPixels(_ value: Int32) -> Component { .init(.formatWidthPixels, value) }
    static func formatHeightPixels(_ value: Int32) -> Component { .init(.formatHeightPixels, value)
    }

    static func formatPixelFormat(_ value: String) -> Component { .init(.formatPixelFormat, value) }
    static func formatMinFramesPerSecond(_ value: Float) -> Component { .init(
        .formatMinFramesPerSecond,
        value
    ) }
    static func formatMaxFramesPerSecond(_ value: Float) -> Component { .init(
        .formatMaxFramesPerSecond,
        value
    ) }
    static func formatMultiCamSupported(_ value: Bool) -> Component { .init(
        .formatMultiCamSupported,
        value
    ) }
    static func formatCount(_ value: UInt32) -> Component { .init(.formatCount, value) }
    static func activeColorSpace(_ value: String) -> Component { .init(.activeColorSpace, value) }
    static func videoRotationDegrees(_ value: Float) -> Component { .init(
        .videoRotationDegrees,
        value
    ) }
    static func videoMirrored(_ value: Bool) -> Component { .init(.videoMirrored, value) }
    static func multiCamSetIndex(_ value: UInt32) -> Component { .init(.multiCamSetIndex, value) }
    static func multiCamSetMembers(_ value: String)
        -> Component { .init(.multiCamSetMembers, value) }
    static func outputPixelFormat(_ value: String) -> Component { .init(.outputPixelFormat, value) }
    static func outputPixelFormatSupported(_ value: Bool) -> Component { .init(
        .outputPixelFormatSupported,
        value
    ) }
    static func framesDeliveredCount(_ value: UInt64) -> Component { .init(
        .framesDeliveredCount,
        value
    ) }
    static func framesDroppedCount(_ value: UInt64)
        -> Component { .init(.framesDroppedCount, value) }
    static func dropReason(_ value: String) -> Component { .init(.dropReason, value) }
    static func delegateDurationNanoseconds(_ value: UInt64) -> Component { .init(
        .delegateDurationNanoseconds,
        value
    ) }
    static func delegateDurationPeakNanoseconds(_ value: UInt64) -> Component { .init(
        .delegateDurationPeakNanoseconds,
        value
    ) }
    static func hangNanoseconds(_ value: UInt64) -> Component { .init(.hangNanoseconds, value) }
    static func hangResolved(_ value: Bool) -> Component { .init(.hangResolved, value) }
    static func runLoopTurnCount(_ value: UInt64) -> Component { .init(.runLoopTurnCount, value) }
    static func threadIndex(_ value: UInt32) -> Component { .init(.threadIndex, value) }
    static func threadName(_ value: String) -> Component { .init(.threadName, value) }
    static func threadIsMain(_ value: Bool) -> Component { .init(.threadIsMain, value) }
    static func frameAddress(_ value: UInt64) -> Component { .init(.frameAddress, value) }
    static func imageName(_ value: String) -> Component { .init(.imageName, value) }
    static func imageLoadAddress(_ value: UInt64) -> Component { .init(.imageLoadAddress, value) }
    static func imageUUID(_ value: String) -> Component { .init(.imageUUID, value) }
    static func buildUUID(_ value: String) -> Component { .init(.buildUUID, value) }
    static func launchId(_ value: UInt64) -> Component { .init(.launchId, value) }
    static func logSubsystem(_ value: String) -> Component { .init(.logSubsystem, value) }
    static func logCategory(_ value: String) -> Component { .init(.logCategory, value) }
    static func logMessage(_ value: String) -> Component { .init(.logMessage, value) }
    static func occurrenceCount(_ value: UInt64) -> Component { .init(.occurrenceCount, value) }
    static func hostRootViewType(_ value: String) -> Component { .init(.hostRootViewType, value) }
    static func hostRootViewOpaque(_ value: Bool) -> Component { .init(.hostRootViewOpaque, value) }
    static func hostNavigationTitle(_ value: String) -> Component { .init(
        .hostNavigationTitle,
        value
    ) }
    static func hostAppearNanoseconds(_ value: UInt64) -> Component { .init(
        .hostAppearNanoseconds,
        value
    ) }
    static func hostKind(_ value: String) -> Component { .init(.hostKind, value) }
    static func hostCount(_ value: UInt32) -> Component { .init(.hostCount, value) }
    static func hostViewClass(_ value: String) -> Component { .init(.hostViewClass, value) }
    static func mechanismStatus(_ value: String) -> Component { .init(.mechanismStatus, value) }
    static func displayListSeed(_ value: UInt32) -> Component { .init(.displayListSeed, value) }
    static func displayListItemCount(_ value: UInt32) -> Component { .init(
        .displayListItemCount,
        value
    ) }
    static func displayListChangeCount(_ value: UInt64) -> Component { .init(
        .displayListChangeCount,
        value
    ) }
    static func ivarPathGeneration(_ value: String)
        -> Component { .init(.ivarPathGeneration, value) }
    static func presentationKind(_ value: String) -> Component { .init(.presentationKind, value) }
    static func presentedRootViewType(_ value: String) -> Component { .init(
        .presentedRootViewType,
        value
    ) }
    static func windowNanoseconds(_ value: UInt64) -> Component { .init(.windowNanoseconds, value) }
    static func memoryLimitBytes(_ value: UInt64) -> Component { .init(.memoryLimitBytes, value) }
    static func memoryAvailableBytes(_ value: UInt64) -> Component { .init(
        .memoryAvailableBytes,
        value
    ) }
    static func memoryPressureLevel(_ value: String) -> Component { .init(
        .memoryPressureLevel,
        value
    ) }
    static func memoryPressureScope(_ value: String) -> Component { .init(
        .memoryPressureScope,
        value
    ) }
    static func exitReason(_ value: String) -> Component { .init(.exitReason, value) }
    static func intervalEndMicroseconds(_ value: UInt64) -> Component { .init(
        .intervalEndMicroseconds,
        value
    ) }
    static func permissionSubject(_ value: String) -> Component { .init(.permissionSubject, value) }
    static func authorizationStatus(_ value: String) -> Component { .init(
        .authorizationStatus,
        value
    ) }
    static func usageDescriptionDeclared(_ value: Bool) -> Component { .init(
        .usageDescriptionDeclared,
        value
    ) }
    static func threadIdentifier(_ value: UInt64) -> Component { .init(.threadIdentifier, value) }
    static func threadRunState(_ value: String) -> Component { .init(.threadRunState, value) }
    static func threadIdle(_ value: Bool) -> Component { .init(.threadIdle, value) }
    static func threadPriority(_ value: Int32) -> Component { .init(.threadPriority, value) }
    static func threadBasePriority(_ value: Int32) -> Component { .init(.threadBasePriority, value)
    }

    static func cpuNanoseconds(_ value: UInt64) -> Component { .init(.cpuNanoseconds, value) }
    static func wakeupCount(_ value: UInt64) -> Component { .init(.wakeupCount, value) }
    static func idleWakeupCount(_ value: UInt64) -> Component { .init(.idleWakeupCount, value) }
    static func queueLatencyNanoseconds(_ value: UInt64) -> Component { .init(
        .queueLatencyNanoseconds,
        value
    ) }
    static func queueLabel(_ value: String) -> Component { .init(.queueLabel, value) }
    static func insertedCount(_ value: UInt32) -> Component { .init(.insertedCount, value) }
    static func updatedCount(_ value: UInt32) -> Component { .init(.updatedCount, value) }
    static func deletedCount(_ value: UInt32) -> Component { .init(.deletedCount, value) }
    static func refreshedCount(_ value: UInt32) -> Component { .init(.refreshedCount, value) }
    static func contextConcurrency(_ value: String)
        -> Component { .init(.contextConcurrency, value) }
    static func confinementViolation(_ value: Bool) -> Component { .init(
        .confinementViolation,
        value
    ) }
    static func logLevel(_ value: String) -> Component { .init(.logLevel, value) }
    static func dnsNanoseconds(_ value: UInt64) -> Component { .init(.dnsNanoseconds, value) }
    static func connectNanoseconds(_ value: UInt64)
        -> Component { .init(.connectNanoseconds, value) }
    static func tlsNanoseconds(_ value: UInt64) -> Component { .init(.tlsNanoseconds, value) }
    static func serverNanoseconds(_ value: UInt64) -> Component { .init(.serverNanoseconds, value) }
    static func responseNanoseconds(_ value: UInt64) -> Component { .init(
        .responseNanoseconds,
        value
    ) }
    static func tlsVersion(_ value: String) -> Component { .init(.tlsVersion, value) }
    static func tlsCipherSuite(_ value: String) -> Component { .init(.tlsCipherSuite, value) }
    static func transactionCount(_ value: UInt32) -> Component { .init(.transactionCount, value) }
    static func requestTimeoutSeconds(_ value: Float) -> Component { .init(
        .requestTimeoutSeconds,
        value
    ) }
    static func resourceTimeoutSeconds(_ value: Float) -> Component { .init(
        .resourceTimeoutSeconds,
        value
    ) }
    static func allowsCellular(_ value: Bool) -> Component { .init(.allowsCellular, value) }
    static func allowsExpensive(_ value: Bool) -> Component { .init(.allowsExpensive, value) }
    static func allowsConstrained(_ value: Bool) -> Component { .init(.allowsConstrained, value) }
    static func waitsForConnectivity(_ value: Bool) -> Component { .init(
        .waitsForConnectivity,
        value
    ) }
    static func maximumConnectionsPerHost(_ value: UInt32) -> Component { .init(
        .maximumConnectionsPerHost,
        value
    ) }
    static func cachePolicy(_ value: String) -> Component { .init(.cachePolicy, value) }
    static func dnsProtocol(_ value: String) -> Component { .init(.dnsProtocol, value) }
    static func remoteAddress(_ value: String) -> Component { .init(.remoteAddress, value) }
    static func proxyConnection(_ value: Bool) -> Component { .init(.proxyConnection, value) }
    static func multipath(_ value: Bool) -> Component { .init(.multipath, value) }
    static func arbitraryLoadsAllowed(_ value: Bool) -> Component { .init(
        .arbitraryLoadsAllowed,
        value
    ) }
    static func exceptionDomain(_ value: String) -> Component { .init(.exceptionDomain, value) }
    static func insecureLoadsAllowed(_ value: Bool) -> Component { .init(
        .insecureLoadsAllowed,
        value
    ) }
    static func minimumTLSVersion(_ value: String) -> Component { .init(.minimumTLSVersion, value) }
    static func deadlineMissCount(_ value: UInt32) -> Component { .init(.deadlineMissCount, value) }
    static func deadlineOverrunNanoseconds(_ value: UInt64) -> Component { .init(
        .deadlineOverrunNanoseconds,
        value
    ) }
    static func presentationLatencyNanoseconds(_ value: UInt64) -> Component { .init(
        .presentationLatencyNanoseconds,
        value
    ) }
    static func settingName(_ value: String) -> Component { .init(.settingName, value) }
    static func settingEnabled(_ value: Bool) -> Component { .init(.settingEnabled, value) }
    static func textSizeCategory(_ value: String) -> Component { .init(.textSizeCategory, value) }
    static func accessibilityTextSize(_ value: Bool) -> Component { .init(
        .accessibilityTextSize,
        value
    ) }
    static func languageCode(_ value: String) -> Component { .init(.languageCode, value) }
    static func regionCode(_ value: String) -> Component { .init(.regionCode, value) }
    static func calendarIdentifier(_ value: String)
        -> Component { .init(.calendarIdentifier, value) }
    static func usesMetricSystem(_ value: Bool) -> Component { .init(.usesMetricSystem, value) }
    static func uses24HourTime(_ value: Bool) -> Component { .init(.uses24HourTime, value) }
    static func layoutDirection(_ value: String) -> Component { .init(.layoutDirection, value) }
    static func changeReason(_ value: String) -> Component { .init(.changeReason, value) }
    static func notificationSetting(_ value: String) -> Component { .init(
        .notificationSetting,
        value
    ) }
    static func settingState(_ value: String) -> Component { .init(.settingState, value) }
    static func alertStyle(_ value: String) -> Component { .init(.alertStyle, value) }
    static func previewVisibility(_ value: String) -> Component { .init(.previewVisibility, value) }
    static func callbackImplemented(_ value: Bool)
        -> Component { .init(.callbackImplemented, value) }
    static func silenceNanoseconds(_ value: UInt64)
        -> Component { .init(.silenceNanoseconds, value) }
    static func accuracyClass(_ value: String) -> Component { .init(.accuracyClass, value) }
    static func callbackCount(_ value: UInt64) -> Component { .init(.callbackCount, value) }
    static func delegateClass(_ value: String) -> Component { .init(.delegateClass, value) }
    static func bluetoothState(_ value: String) -> Component { .init(.bluetoothState, value) }
    static func contentProcessTerminations(_ value: UInt64) -> Component { .init(
        .contentProcessTerminations,
        value
    ) }
    static func tileLoadFailures(_ value: UInt64) -> Component { .init(.tileLoadFailures, value) }
    static func mapLoadsCompleted(_ value: UInt64) -> Component { .init(.mapLoadsCompleted, value) }
    static func callAction(_ value: String) -> Component { .init(.callAction, value) }
    static func audioOutputPort(_ value: String) -> Component { .init(.audioOutputPort, value) }
    static func audioOutputName(_ value: String) -> Component { .init(.audioOutputName, value) }
    static func audioInputPort(_ value: String) -> Component { .init(.audioInputPort, value) }
    static func audioCategory(_ value: String) -> Component { .init(.audioCategory, value) }
    static func audioMode(_ value: String) -> Component { .init(.audioMode, value) }
    static func audioCategoryOptions(_ value: String) -> Component { .init(
        .audioCategoryOptions,
        value
    ) }
    static func audioPreviousOutputPort(_ value: String) -> Component { .init(
        .audioPreviousOutputPort,
        value
    ) }
    static func audioRouteVerdict(_ value: String) -> Component { .init(.audioRouteVerdict, value) }
    static func audioInputName(_ value: String) -> Component { .init(.audioInputName, value) }
    static func audioInputDataSource(_ value: String) -> Component { .init(
        .audioInputDataSource,
        value
    ) }
    static func audioInputPolarPattern(_ value: String) -> Component { .init(
        .audioInputPolarPattern,
        value
    ) }
    static func audioInputOrientation(_ value: String) -> Component { .init(
        .audioInputOrientation,
        value
    ) }
    static func audioInputVerdict(_ value: String) -> Component { .init(.audioInputVerdict, value) }
    static func audioInputAvailable(_ value: Bool) -> Component { .init(
        .audioInputAvailable,
        value
    ) }
    static func audioPreferredInputHonored(_ value: Bool) -> Component { .init(
        .audioPreferredInputHonored,
        value
    ) }
    static func availableInputCount(_ value: UInt32) -> Component { .init(
        .availableInputCount,
        value
    ) }
    static func audioOutputCount(_ value: UInt32) -> Component { .init(.audioOutputCount, value) }
    static func outputVolume(_ value: Float) -> Component { .init(.outputVolume, value) }
    static func otherAudioPlaying(_ value: Bool) -> Component { .init(.otherAudioPlaying, value) }
    static func secondaryAudioSilenced(_ value: Bool) -> Component { .init(
        .secondaryAudioSilenced,
        value
    ) }
    static func sampleCount(_ value: UInt64) -> Component { .init(.sampleCount, value) }
    static func unwindFailureCount(_ value: UInt64) -> Component { .init(
        .unwindFailureCount,
        value
    ) }
    static func drawableRequestCount(_ value: UInt64) -> Component { .init(
        .drawableRequestCount,
        value
    ) }
    static func drawableSkippedCount(_ value: UInt64) -> Component { .init(
        .drawableSkippedCount,
        value
    ) }
    static func drawableUnavailableCount(_ value: UInt64) -> Component { .init(
        .drawableUnavailableCount,
        value
    ) }
    static func gpuWaitNanoseconds(_ value: UInt64) -> Component { .init(
        .gpuWaitNanoseconds,
        value
    ) }
    static func gpuWaitPeakNanoseconds(_ value: UInt64) -> Component { .init(
        .gpuWaitPeakNanoseconds,
        value
    ) }
    static func gpuExecutionNanoseconds(_ value: UInt64) -> Component { .init(
        .gpuExecutionNanoseconds,
        value
    ) }
    static func gpuExecutionPeakNanoseconds(_ value: UInt64) -> Component { .init(
        .gpuExecutionPeakNanoseconds,
        value
    ) }
    static func frameBudgetNanoseconds(_ value: UInt64) -> Component { .init(
        .frameBudgetNanoseconds,
        value
    ) }
    static func overBudgetCount(_ value: UInt64) -> Component { .init(
        .overBudgetCount,
        value
    ) }
    static func imageTextBytes(_ value: UInt64) -> Component { .init(
        .imageTextBytes,
        value
    ) }
    static func bundledImageCount(_ value: UInt64) -> Component { .init(
        .bundledImageCount,
        value
    ) }
    static func methodClass(_ value: String) -> Component { .init(.methodClass, value) }
    static func ownedByDeclaringImage(_ value: Bool) -> Component { .init(
        .ownedByDeclaringImage,
        value
    ) }
    static func implementationInMappedImage(_ value: Bool) -> Component { .init(
        .implementationInMappedImage,
        value
    ) }
    static func threadRequestedQos(_ value: String) -> Component { .init(
        .threadRequestedQos,
        value
    ) }
    static func touchPhase(_ value: String) -> Component { .init(.touchPhase, value) }
    static func activeTouchCount(_ value: UInt32) -> Component { .init(
        .activeTouchCount,
        value
    ) }
    static func touchesMovedCount(_ value: UInt32) -> Component { .init(
        .touchesMovedCount,
        value
    ) }
    static func dragDistancePoints(_ value: UInt32) -> Component { .init(
        .dragDistancePoints,
        value
    ) }
    static func maximumSimultaneousTouchCount(_ value: UInt32) -> Component { .init(
        .maximumSimultaneousTouchCount,
        value
    ) }
    static func touchId(_ value: UInt32) -> Component { .init(.touchId, value) }
    static func originXPoints(_ value: Double) -> Component { .init(.originXPoints, value) }
    static func originYPoints(_ value: Double) -> Component { .init(.originYPoints, value) }
    static func frameWidthPoints(_ value: Double) -> Component { .init(
        .frameWidthPoints,
        value
    ) }
    static func frameHeightPoints(_ value: Double) -> Component { .init(
        .frameHeightPoints,
        value
    ) }
    static func runtimeClassName(_ value: String) -> Component { .init(
        .runtimeClassName,
        value
    ) }
    static func gestureRecognizerState(_ value: String) -> Component { .init(
        .gestureRecognizerState,
        value
    ) }
    static func viewId(_ value: UInt32) -> Component { .init(.viewId, value) }
    static func viewParent(_ value: UInt32) -> Component { .init(.viewParent, value) }
    static func nestedLevel(_ value: UInt32) -> Component { .init(.nestedLevel, value) }
    static func faultId(_ value: UInt32) -> Component { .init(.faultId, value) }
    static func renderDestination(_ value: String) -> Component {
        .init(.renderDestination, value)
    }

    static func textureBackedImageCount(_ value: UInt64) -> Component {
        .init(.textureBackedImageCount, value)
    }

    static func emptyResultCount(_ value: UInt64) -> Component {
        .init(.emptyResultCount, value)
    }

    static func debuggerAttached(_ value: Bool) -> Component {
        .init(.debuggerAttached, value)
    }

    static func interfaceOrientation(_ value: String) -> Component {
        .init(.interfaceOrientation, value)
    }

    static func activeInstrument(_ value: UInt16) -> Component {
        .init(.activeInstrument, value)
    }
}
