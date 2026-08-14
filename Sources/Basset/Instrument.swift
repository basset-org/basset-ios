import BassetECS
import Foundation

/// What the runner consults. Descriptive metadata lives in `InstrumentMetadata`, not here.
public protocol Instrument: AnyObject {
    static var id: InstrumentID { get }
    static var entity: Entity.ID { get }
    /// Declared rather than inferred: the runner builds the tally before the instrument exists.
    static var tallySlots: Int { get }
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
}

public protocol SnapshotInstrument: Instrument {
    init()
    func reading(_ out: inout Readings)
}

public protocol StreamingInstrument: Instrument {
    init()
    func observe(_ context: Context)
    func stopObserving()
}

public protocol FaultInstrument: Instrument {
    init()
    func fault(_ kind: FaultKind, _ out: inout Readings)
}

public protocol ConfigurableSnapshotInstrument: Instrument {
    associatedtype Config: Decodable & Sendable
    static var defaultConfig: Config { get }
    init(config: Config)
    func reading(_ out: inout Readings)
}

public protocol ConfigurableStreamingInstrument: Instrument {
    associatedtype Config: Decodable & Sendable
    static var defaultConfig: Config { get }
    init(config: Config)
    func observe(_ context: Context)
    func stopObserving()
}

public protocol ConfigurableFaultInstrument: Instrument {
    associatedtype Config: Decodable & Sendable
    static var defaultConfig: Config { get }
    init(config: Config)
    func fault(_ kind: FaultKind, _ out: inout Readings)
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
    public let entity: Entity.ID
    public let availability: Availability
    public let delivery: Delivery
    public let tallySlots: Int

    /// Never throws. `configRefused` means config was sent and did not decode, not that none was.
    let build: @Sendable (Data?) -> (instrument: any Instrument, configRefused: Bool)
    /// Not @Sendable: captures a metatype, immutable but not modeled as such by the compiler.
    let installAtLoad: ((HookTable) -> Void)?

    /// Lets the host build ask for a description; the device build never reads this.
    let instrumentType: any Instrument.Type

    private init<I: Instrument>(
        _ type: I.Type,
        delivery: Delivery,
        build: @escaping @Sendable (Data?) -> (instrument: any Instrument, configRefused: Bool)
    ) {
        self.id = I.id
        self.name = I.name
        self.domain = I.domain
        self.entity = I.entity
        self.availability = I.id.availability
        self.delivery = delivery
        self.tallySlots = I.tallySlots
        self.build = build
        if let loading = I.self as? any LoadTimeInstall.Type {
            self.installAtLoad = { hooks in loading.installAtLoad(hooks) }
        } else {
            self.installAtLoad = nil
        }
        self.instrumentType = I.self
    }

    public static func reading(_ type: (some SnapshotInstrument).Type) -> Registration {
        Registration(type, delivery: .reading, build: { _ in (type.init(), false) })
    }

    public static func reading<I: ConfigurableSnapshotInstrument>(_ type: I.Type) -> Registration {
        Registration(type, delivery: .reading, build: { data in
            let decoded = decodedConfig(data, defaultingTo: I.defaultConfig)
            return (I(config: decoded.config), decoded.refused)
        })
    }

    public static func stream(_ type: (some StreamingInstrument).Type) -> Registration {
        Registration(type, delivery: .stream, build: { _ in (type.init(), false) })
    }

    public static func stream<I: ConfigurableStreamingInstrument>(_ type: I.Type) -> Registration {
        Registration(type, delivery: .stream, build: { data in
            let decoded = decodedConfig(data, defaultingTo: I.defaultConfig)
            return (I(config: decoded.config), decoded.refused)
        })
    }

    public static func fault(_ type: (some FaultInstrument).Type) -> Registration {
        Registration(type, delivery: .fault, build: { _ in (type.init(), false) })
    }

    public static func fault<I: ConfigurableFaultInstrument>(_ type: I.Type) -> Registration {
        Registration(type, delivery: .fault, build: { data in
            let decoded = decodedConfig(data, defaultingTo: I.defaultConfig)
            return (I(config: decoded.config), decoded.refused)
        })
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
