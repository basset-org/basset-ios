import Foundation

struct BassetRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case instruments
        case atLaunch = "at_launch"
        case expiresAt = "expires_at"
        case maxFrames = "max_frames"
        case requestToken = "request_token"
    }

    let requestId: UInt64
    let instruments: [String]
    let atLaunch: Bool
    let expiresAt: Date
    let maxFrames: UInt32?

    let requestToken: String?

    var withoutToken: BassetRequest {
        BassetRequest(
            requestId: requestId,
            instruments: instruments,
            atLaunch: atLaunch,
            expiresAt: expiresAt,
            maxFrames: maxFrames,
            requestToken: nil
        )
    }

    init(
        requestId: UInt64,
        instruments: [String],
        atLaunch: Bool,
        expiresAt: Date,
        maxFrames: UInt32?,
        requestToken: String?
    ) {
        self.requestId = requestId
        self.instruments = instruments
        self.atLaunch = atLaunch
        self.expiresAt = expiresAt
        self.maxFrames = maxFrames
        self.requestToken = requestToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(UInt64.self, forKey: .requestId)
        instruments = try container.decode([String].self, forKey: .instruments)
        atLaunch = try container.decodeIfPresent(Bool.self, forKey: .atLaunch) ?? false
        maxFrames = try container.decodeIfPresent(UInt32.self, forKey: .maxFrames)
        requestToken = try container.decodeIfPresent(String.self, forKey: .requestToken)

        let expiry = try container.decode(String.self, forKey: .expiresAt)
        guard let parsed = Timestamps.parse(expiry) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "expires_at is not an RFC 3339 timestamp: \(expiry)"
            )
        }

        expiresAt = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(instruments, forKey: .instruments)
        try container.encode(atLaunch, forKey: .atLaunch)
        try container.encode(Timestamps.render(expiresAt), forKey: .expiresAt)
        try container.encodeIfPresent(maxFrames, forKey: .maxFrames)
        try container.encodeIfPresent(requestToken, forKey: .requestToken)
    }

    func isLive(at moment: Date) -> Bool {
        expiresAt > moment
    }
}

struct DeviceResponse: Decodable, Sendable {
    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case ingestEndpoint = "ingest_endpoint"
        case requests
    }

    let deviceToken: String
    let ingestEndpoint: String
    let requests: [BassetRequest]
}

struct RequestsResponse: Decodable, Sendable {
    let requests: [BassetRequest]
}

enum Timestamps {
    /// A value, not `ISO8601DateFormatter`: that is a class with mutable options
    /// and cannot be shared across the queues that read a request. It also caps
    /// fractional seconds at three digits, where the control plane sends six.
    private static let iso8601: Date.ISO8601FormatStyle = .init()

    static func parse(_ text: String) -> Date? {
        try? iso8601.parse(text)
    }

    static func render(_ date: Date) -> String {
        iso8601.format(date)
    }
}
