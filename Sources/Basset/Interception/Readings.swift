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

    /// `entityId`/`entityParent`/`nestedLevel` together, so a call site writes one line rather
    /// than three. `parent` is `0` for a root — a reading can have more than one.
    public mutating func putStructure(id: UInt32, parent: UInt32, level: UInt32) {
        put(.entityId(id))
        put(.entityParent(parent))
        put(.nestedLevel(level))
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
