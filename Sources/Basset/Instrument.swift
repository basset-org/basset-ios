import BassetECS
import Foundation

/// What the runner consults. Descriptive metadata lives in `InstrumentMetadata`, not here.
public protocol Instrument: AnyObject {
    static var id: InstrumentID { get }
    static var entity: Entity.ID { get }
    /// Declared rather than inferred: the runner builds the tally before the instrument exists.
    static var tallySlots: Int { get }
    init()
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
    func reading(_ out: inout Readings)
}

public protocol StreamingInstrument: Instrument {
    func observe(_ context: Context)
    func stopObserving()
}

public protocol FaultInstrument: Instrument {
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

    let build: @Sendable () -> any Instrument
    /// Not @Sendable: captures a metatype, immutable but not modeled as such by the compiler.
    let installAtLoad: ((HookTable) -> Void)?

    /// Lets the host build ask for a description; the device build never reads this.
    let instrumentType: any Instrument.Type

    private init<I: Instrument>(_ type: I.Type, delivery: Delivery) {
        self.id = I.id
        self.name = I.name
        self.domain = I.domain
        self.entity = I.entity
        self.availability = I.id.availability
        self.delivery = delivery
        self.tallySlots = I.tallySlots
        self.build = { I() }
        if let loading = I.self as? any LoadTimeInstall.Type {
            self.installAtLoad = { hooks in loading.installAtLoad(hooks) }
        } else {
            self.installAtLoad = nil
        }
        self.instrumentType = I.self
    }

    public static func reading(_ type: (some SnapshotInstrument).Type) -> Registration {
        Registration(type, delivery: .reading)
    }

    public static func stream(_ type: (some StreamingInstrument).Type) -> Registration {
        Registration(type, delivery: .stream)
    }

    public static func fault(_ type: (some FaultInstrument).Type) -> Registration {
        Registration(type, delivery: .fault)
    }
}

public extension Registration {
    /// An unavailable instrument is ignored the same way an unknown one is.
    var isAvailableHere: Bool {
        availability.isSatisfiedHere
    }
}
