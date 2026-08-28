import Foundation

struct BassetRequest: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case instruments
        case instrumentConfig = "instrument_config"
        case atLaunch = "at_launch"
        case expiresAt = "expires_at"
        case maxFrames = "max_frames"
        case requestToken = "request_token"
    }

    /// Device-side backstops: a control plane cannot pin instruments hot past this
    /// horizon, or stream more than this many frames, whatever a response asks for.
    static let maximumLifetime: TimeInterval = 24 * 60 * 60
    static let maximumFrames: UInt32 = 1000000

    let requestId: UInt64
    let instruments: [String]
    /// Raw per instrument — `Registration.build` decodes the real `Config` at activation.
    let instrumentConfig: [String: Data]
    let atLaunch: Bool
    let expiresAt: Date
    let maxFrames: UInt32?

    let requestToken: String?

    var withoutToken: BassetRequest {
        BassetRequest(
            requestId: requestId,
            instruments: instruments,
            instrumentConfig: instrumentConfig,
            atLaunch: atLaunch,
            expiresAt: expiresAt,
            maxFrames: maxFrames,
            requestToken: nil
        )
    }

    init(
        requestId: UInt64,
        instruments: [String],
        instrumentConfig: [String: Data] = [:],
        atLaunch: Bool,
        expiresAt: Date,
        maxFrames: UInt32?,
        requestToken: String?
    ) {
        self.requestId = requestId
        self.instruments = instruments
        self.instrumentConfig = instrumentConfig
        self.atLaunch = atLaunch
        self.expiresAt = expiresAt
        self.maxFrames = maxFrames
        self.requestToken = requestToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(UInt64.self, forKey: .requestId)
        instruments = try container.decode([String].self, forKey: .instruments)
        // Missing or malformed both mean the same: no config, the default applies.
        let named = try? container.decodeIfPresent(
            [String: JSONValue].self,
            forKey: .instrumentConfig
        )
        instrumentConfig = (named ?? [:]).compactMapValues { try? JSONEncoder().encode($0) }
        atLaunch = try container.decodeIfPresent(Bool.self, forKey: .atLaunch) ?? false
        requestToken = try container.decodeIfPresent(String.self, forKey: .requestToken)

        let requested = try container.decodeIfPresent(UInt32.self, forKey: .maxFrames)
        maxFrames = min(requested ?? Self.maximumFrames, Self.maximumFrames)

        let expiry = try container.decode(String.self, forKey: .expiresAt)
        guard let parsed = Timestamps.parse(expiry) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: container,
                debugDescription: "expires_at is not an RFC 3339 timestamp: \(expiry)"
            )
        }

        expiresAt = min(parsed, Date(timeIntervalSinceNow: Self.maximumLifetime))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(instruments, forKey: .instruments)
        if !instrumentConfig.isEmpty {
            let named = instrumentConfig.compactMapValues { try? JSONDecoder().decode(
                JSONValue.self,
                from: $0
            ) }
            try container.encode(named, forKey: .instrumentConfig)
        }
        try container.encode(atLaunch, forKey: .atLaunch)
        try container.encode(Timestamps.render(expiresAt), forKey: .expiresAt)
        try container.encodeIfPresent(maxFrames, forKey: .maxFrames)
        try container.encodeIfPresent(requestToken, forKey: .requestToken)
    }

    func isLive(at moment: Date) -> Bool {
        expiresAt > moment
    }
}

/// A JSON value of unknown shape, decoded before the owning instrument sees its `Config`.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    /// Tried before `number`: an integer past 2^53 loses precision going through `Double`.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        var container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct DesiredState: Decodable, Sendable {
    enum CodingKeys: String, CodingKey {
        case ingestEndpoint = "ingest_endpoint"
        case requests
        case stateVersion = "state_version"
    }

    let ingestEndpoint: String
    let requests: [BassetRequest]
    /// Echoed on the next poll so the control plane answers at once when it has moved on.
    let stateVersion: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ingestEndpoint = try container.decode(String.self, forKey: .ingestEndpoint)
        requests = try container
            .decodeIfPresent(LenientRequestList.self, forKey: .requests)?
            .requests ?? []
        stateVersion = try? container.decodeIfPresent(String.self, forKey: .stateVersion)
    }
}

/// One malformed request is skipped rather than failing every request beside it.
struct LenientRequestList: Decodable, Sendable {
    private struct Discard: Decodable {
        init(from decoder: Decoder) {}
    }

    let requests: [BassetRequest]

    init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var collected = [BassetRequest]()
        while !list.isAtEnd {
            let index = list.currentIndex
            if let request = try? list.decode(BassetRequest.self) {
                collected.append(request)
            } else if (try? list.decodeNil()) != true {
                _ = try? list.decode(Discard.self)
            }
            // An element nothing above consumed would spin here forever.
            if list.currentIndex == index {
                break
            }
        }
        requests = collected
    }
}

enum Timestamps {
    /// Two styles tried in order: fractional-seconds support isn't guaranteed either way.
    private static let fractional: Date.ISO8601FormatStyle = .init(
        includingFractionalSeconds: true
    )
    private static let whole: Date.ISO8601FormatStyle = .init()

    static func parse(_ text: String) -> Date? {
        if let moment = try? fractional.parse(text) {
            return moment
        }

        return try? whole.parse(text)
    }

    static func render(_ date: Date) -> String {
        whole.format(date)
    }
}
