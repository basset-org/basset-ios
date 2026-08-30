import BassetEntityComponent
import Foundation

public struct Readings {
    public let entity: Entity.ID

    private let capturedAt: UInt64
    private var components: [Component] = []
    private var additional: [Entity] = []

    public var isEmpty: Bool {
        components.isEmpty
    }

    public init(_ entity: Entity.ID) {
        self.entity = entity
        capturedAt = Entity.microsecondsSinceEpoch()
    }

    public mutating func put(_ component: Component) {
        components.append(component)
    }

    /// Stamped on the record and every additional entity this reading has produced so far — for
    /// a correlation id minted after an instrument's own `fault`/`observe` has already built its
    /// readings, e.g. `faultId`, which every fault contributor's output carries without that
    /// instrument's own code needing to know it exists.
    public mutating func tagEveryEntity(with component: Component) {
        components.append(component)
        additional = additional.map { entity in
            Entity(
                entity.id,
                capturedAt: entity.capturedAt,
                components: entity.components + [component]
            )
        }
    }

    /// A second entity from the same firing — splits a thread snapshot's stacks apart.
    public mutating func also(_ entity: Entity.ID,
                              _ build: (inout Readings) -> Void)
    {
        var next = Readings(entity)
        build(&next)
        guard !next.isEmpty else {
            return
        }

        additional.append(next.build())
        additional.append(contentsOf: next.additionalEntities())
    }

    /// What `InstrumentRunner` stamps onto every reading it routes through a live request —
    /// exposed so a caller emitting outside that path, like the attached identity ack, tags
    /// its reading the same way rather than leaving it unattributable.
    public func tagged(_ instrument: InstrumentID) -> Entity {
        let record = build()
        return Entity(
            record.id,
            capturedAt: record.capturedAt,
            components: record.components + [
                .instrument(instrument.rawValue),
                .launchId(LaunchIdentity.current),
            ]
        )
    }

    func build() -> Entity {
        Entity(entity, capturedAt: capturedAt, components: components)
    }

    func additionalEntities() -> [Entity] {
        additional
    }
}
