import BassetECS
import Foundation

public struct Readings {
    public let entity: Entity.ID

    private let instrumentName: String
    private var record: Entity
    private var written: Set<Component.ID> = []
    private var siblings: [Entity] = []

    public var isEmpty: Bool {
        record.components.isEmpty
    }

    public var componentsWritten: Set<Component.ID> {
        written
    }

    init(entity: Entity.ID, instrumentName: String) {
        self.entity = entity
        self.instrumentName = instrumentName
        self.record = Entity(entity)
    }

    public mutating func put(_ component: Component) {
        written.insert(component.id)
        record.add(component)
    }

    /// Stamped on the record and every sibling this reading has produced so far — for a
    /// correlation id minted after an instrument's own `fault`/`observe` has already built its
    /// readings, e.g. `faultId`, which every fault contributor's output carries without that
    /// instrument's own code needing to know it exists.
    public mutating func tagEveryEntity(with component: Component) {
        record.add(component)
        siblings = siblings.map { sibling in
            var sibling = sibling
            sibling.add(component)
            return sibling
        }
    }

    /// A second entity from the same firing — splits a thread snapshot's stacks apart.
    public mutating func also(_ entity: Entity.ID,
                              _ build: (inout Readings) -> Void)
    {
        var sibling = Readings(entity: entity, instrumentName: instrumentName)
        build(&sibling)
        guard !sibling.isEmpty else {
            return
        }

        siblings.append(sibling.sealed())
        siblings.append(contentsOf: sibling.sealedSiblings())
    }

    func sealed() -> Entity {
        record
    }

    func sealedSiblings() -> [Entity] {
        siblings
    }
}
