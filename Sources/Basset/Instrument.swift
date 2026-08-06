import BassetECS
import Foundation

/// What the runner consults, and nothing else. Mechanism, cadence, overhead and
/// App Store standing describe an instrument to a reader; no code path on the
/// device reads them, so they live in `InstrumentMetadata` rather than here,
/// where a reader cannot tell which fields decide anything.
public protocol Instrument: AnyObject {
    static var id: InstrumentWireID { get }
    static var entity: Entity.WireID { get }
    init()
}

public extension Instrument {
    static var name: String {
        id.name
    }

    static var domain: Domain {
        id.domain
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
    public let id: InstrumentWireID
    public let name: String
    public let domain: Domain
    public let entity: Entity.WireID
    public let availability: Availability
    public let delivery: Delivery

    let build: @Sendable () -> any Instrument
    /// Not @Sendable: it captures an instrument's metatype, which is immutable and
    /// safe to hand across threads, and which the compiler does not model as such.
    /// This struct carries the unchecked conformance that covers it.
    let installAtLoad: ((HookTable) -> Void)?

    /// The type itself, so the host build that emits the menu can ask it for the
    /// description while the device build — which has no InstrumentMetadata at all
    /// — carries only a metatype it already had.
    let instrumentType: any Instrument.Type

    private init<I: Instrument>(_ type: I.Type, delivery: Delivery) {
        self.id = I.id
        self.name = I.name
        self.domain = I.domain
        self.entity = I.entity
        self.availability = I.id.availability
        self.delivery = delivery
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
    /// Two independent reasons an instrument may not run on the device in hand:
    /// the hardware it observes is absent from a simulator, and the API its
    /// mechanism needs postdates this OS. Both are declared, and the runner
    /// refuses to activate what fails either — a request naming an unavailable
    /// instrument is ignored the same way one naming an unknown instrument is.
    var isAvailableHere: Bool {
        availability.isSatisfiedHere
    }
}
