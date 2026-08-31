import BassetEntityComponent
import Foundation

/// What the runner consults. Descriptive metadata lives in `InstrumentMetadata`, not here.
public protocol Instrument: AnyObject {
    static var id: InstrumentID { get }
    /// Declared rather than inferred: the runner builds the tally before the instrument exists.
    static var tallySlots: Int { get }
    /// Whether this device's own runtime has anything for this instrument to observe —
    /// distinct from `Availability`, which asks only whether the mechanism compiles here.
    /// Answered from `registries`, already filled by every load-time hook regardless of
    /// activation, so the probe costs nothing an inactive instrument wasn't already paying.
    static func relevance(_ registries: Registries) -> Relevance
}

public extension Instrument {
    static var name: String {
        id.name
    }

    static var domain: Domain {
        id.domain
    }

    /// Enough for the count/total/peak an aggregate usually keeps.
    static var tallySlots: Int {
        4
    }

    /// Most instruments have something to say on any device — a hang or a memory
    /// footprint exists whether or not the app happens to touch a given subsystem.
    static func relevance(_ registries: Registries) -> Relevance {
        .relevant
    }
}

/// Whether an instrument's own runtime probe found this device worth activating it on.
public enum Relevance: Sendable, Equatable {
    case relevant
    case notRelevant
}

/// What the runner dispatches to — plain and `Configurable` instruments both conform.
public protocol Snapshotable: Instrument {
    func reading() -> Readings
}

public protocol Streamable: Instrument {
    func observe(_ context: Context)
    func stopObserving()
}

public protocol Faultable: Instrument {
    func fault(_ kind: FaultKind) -> Readings
}

/// `init()` lives here, not on `Instrument`, so a `Configurable` instrument need not have one.
public protocol PlainInstrument: Instrument {
    init()
}

public protocol Configurable: Instrument {
    /// `Encodable` too, so `defaultConfig` round-trips through the same decode a request uses.
    associatedtype Config: Codable & Sendable
    static var defaultConfig: Config { get }
    init(config: Config)
}

public protocol LoadTimeInstall: Instrument {
    static func installAtLoad(_ hooks: HookTable)
}

public enum FaultKind: String, Sendable {
    case hang
    case termination
    case memoryPressure
}

public struct Registration: @unchecked Sendable {
    public let id: InstrumentID
    public let name: String
    public let domain: Domain
    public let availability: Availability
    public let delivery: Delivery
    public let tallySlots: Int

    /// Not `Sendable`-checked as a stored closure since `Registries` already is; captures
    /// only the metatype `I.relevance` dispatches through.
    let relevance: @Sendable (Registries) -> Relevance

    /// Never throws. `configRefused` means config was sent and did not decode, not that none was.
    let build: @Sendable (Data?) -> (instrument: any Instrument, configRefused: Bool)
    /// Not @Sendable: captures a metatype, immutable but not modeled as such by the compiler.
    let installAtLoad: ((HookTable) -> Void)?

    /// Lets the host build ask for a description; the device build never reads this.
    let instrumentType: any Instrument.Type

    /// `defaultConfig`, re-encoded — lets a host test prove it decodes, without knowing `Config`.
    let defaultConfigJSON: Data?

    private init<I: Instrument>(
        _ type: I.Type,
        delivery: Delivery,
        defaultConfigJSON: Data? = nil,
        build: @escaping @Sendable (Data?) -> (instrument: any Instrument, configRefused: Bool)
    ) {
        self.id = I.id
        self.name = I.name
        self.domain = I.domain
        self.availability = I.id.availability
        self.delivery = delivery
        self.tallySlots = I.tallySlots
        self.relevance = { I.relevance($0) }
        self.build = build
        if let loading = I.self as? any LoadTimeInstall.Type {
            self.installAtLoad = { hooks in loading.installAtLoad(hooks) }
        } else {
            self.installAtLoad = nil
        }
        self.instrumentType = I.self
        self.defaultConfigJSON = defaultConfigJSON
    }

    public static func reading(_ type: (some Snapshotable & PlainInstrument).Type) -> Registration {
        Registration(type, delivery: .reading, build: { data in (type.init(), data != nil) })
    }

    public static func reading<I: Snapshotable & Configurable>(_ type: I.Type) -> Registration {
        Registration(
            type,
            delivery: .reading,
            defaultConfigJSON: try? JSONEncoder().encode(I.defaultConfig),
            build: { data in
                let decoded = decodedConfig(data, defaultingTo: I.defaultConfig)
                return (I(config: decoded.config), decoded.refused)
            }
        )
    }

    public static func stream(_ type: (some Streamable & PlainInstrument).Type) -> Registration {
        Registration(type, delivery: .stream, build: { data in (type.init(), data != nil) })
    }

    public static func stream<I: Streamable & Configurable>(_ type: I.Type) -> Registration {
        Registration(
            type,
            delivery: .stream,
            defaultConfigJSON: try? JSONEncoder().encode(I.defaultConfig),
            build: { data in
                let decoded = decodedConfig(data, defaultingTo: I.defaultConfig)
                return (I(config: decoded.config), decoded.refused)
            }
        )
    }

    public static func fault(_ type: (some Faultable & PlainInstrument).Type) -> Registration {
        Registration(type, delivery: .fault, build: { data in (type.init(), data != nil) })
    }

    public static func fault<I: Faultable & Configurable>(_ type: I.Type) -> Registration {
        Registration(
            type,
            delivery: .fault,
            defaultConfigJSON: try? JSONEncoder().encode(I.defaultConfig),
            build: { data in
                let decoded = decodedConfig(data, defaultingTo: I.defaultConfig)
                return (I(config: decoded.config), decoded.refused)
            }
        )
    }
}

/// No config sent is the ordinary case; only sent-but-undecodable config is `refused`.
private func decodedConfig<Config: Decodable>(
    _ data: Data?,
    defaultingTo fallback: Config
) -> (config: Config, refused: Bool) {
    guard let data else {
        return (fallback, false)
    }
    guard let decoded = try? JSONDecoder().decode(Config.self, from: data) else {
        return (fallback, true)
    }

    return (decoded, false)
}

public extension Registration {
    /// An unavailable instrument is ignored the same way an unknown one is.
    var isAvailableHere: Bool {
        availability.isSatisfiedHere
    }
}
