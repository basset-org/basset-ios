import Foundation

/// One reading: what it is about, when it was taken, and the components that
/// describe it.
public struct Entity: Equatable, Sendable {
    public enum ID: UInt16, Sendable, CaseIterable {
        case unknown = 0
        case device = 1
        case methodCall = 2
        case login = 3
        case serverVersion = 4
        case process = 5
        case thermal = 6
        case captureSession = 7
        case screen = 8
        case viewLayout = 9
        case networkTask = 10
        case networkPath = 11
        case appLifecycle = 12
        case captureDevice = 13
        case multiCamSet = 14
        case videoFrames = 15
        case mainThread = 16
        case thread = 17
        case binaryImage = 18
        case swiftUIHost = 19
        case swiftUIRuntimeIssue = 20
        case swiftUIPresentation = 21
        case swiftUIDisplayList = 22
        case memoryPressure = 23
        case appExit = 24
        case permission = 25
        case dispatchQueue = 26
        case managedObjectContext = 27
        case logRecord = 28
        case networkSession = 29
        case transportSecurity = 30
        case displayUpdate = 31
        case deviceSetting = 32
        case cloudSync = 33
        case keyValueStore = 34
        case notificationSetting = 35
        case locationDelegate = 36
        case bluetoothCentral = 37
        case webView = 38
        case mapView = 39
        case callProvider = 40
        case audioRoute = 41
    }

    public let id: ID
    public let capturedAt: UInt64
    public private(set) var components: [Component] = []

    /// What this reading says, without when it was said. Two readings sharing a
    /// fingerprint report the same state at different moments, which is the
    /// difference between a fact worth sending twice and a mechanism firing
    /// twice — KVO notifies on every set, not on every change.
    public var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(id)
        for component in components {
            hasher.combine(component.id)
            hasher.combine(component.value.rendered)
        }
        return hasher.finalize()
    }

    public init(_ id: ID, capturedAt: UInt64 = Entity.microsecondsSinceEpoch()) {
        self.id = id
        self.capturedAt = capturedAt
    }

    public static func microsecondsSinceEpoch() -> UInt64 {
        var wallClock = timespec()
        clock_gettime(CLOCK_REALTIME, &wallClock)
        return UInt64(wallClock.tv_sec) * 1000000 + UInt64(wallClock.tv_nsec) / 1000
    }

    public mutating func add(_ component: Component) {
        components.append(component)
    }
}

// MARK: CustomStringConvertible

extension Entity: CustomStringConvertible {
    public var description: String {
        var lines = ["\(id):"]
        for component in components {
            lines.append("  \(component.id): \(component.value.rendered)")
        }
        return lines.joined(separator: "\n")
    }
}
