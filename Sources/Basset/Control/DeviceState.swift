import Foundation

public struct DeviceState: Sendable {
    public let deviceId: String
    public let model: String
    public let os: String
    public let appVersion: String
    public let bundleId: String?
    public let buildConfiguration: String
    public let deviceKind: String
    public let control: URL
    public let userId: String?
    public let lastCtrlResponse: CtrlResponse?
    public let requests: [RequestState]
    public let activeInstruments: [String]
}

public struct CtrlResponse: Sendable {
    public enum Outcome: Sendable, Equatable {
        case accepted(requestCount: Int)
        case unauthorized
        case refused(status: Int)
        case unreachable(String)
    }

    public let outcome: Outcome
    public let at: Date

    public init(outcome: Outcome, at: Date) {
        self.outcome = outcome
        self.at = at
    }
}

public struct RequestState: Sendable {
    public let requestId: UInt64
    public let instruments: [String]
    public let atLaunch: Bool
    public let expiresAt: Date
    public let maxFrames: UInt32?
    public let framesSent: Int
    public let framesHeld: Int

    public let framesDropped: Int
    public let transport: TransportType?
    public let transportIsReady: Bool

    public let transportNote: String?

    public let refused: String?
}

public enum TransportType: String, Sendable {
    case quic
    case http2
}
