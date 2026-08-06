import BassetECS
import Foundation

public struct Readings {
    public let entity: Entity.WireID

    private let instrumentName: String
    private var record: Entity
    private var written: Set<Component.WireID> = []
    private var siblings: [Entity] = []

    public var isEmpty: Bool {
        record.components.isEmpty
    }

    public var componentsWritten: Set<Component.WireID> {
        written
    }

    init(entity: Entity.WireID, instrumentName: String) {
        self.entity = entity
        self.instrumentName = instrumentName
        self.record = Entity(entity)
    }

    public mutating func put(_ component: Component) {
        written.insert(component.id)
        record.add(component)
    }

    /// A second entity from the same firing. One thread snapshot is many
    /// stacks and the images they land in; splitting them lets a reader take
    /// one thread without decoding the rest, and costs the instrument nothing
    /// but this call.
    public mutating func also(_ entity: Entity.WireID,
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
