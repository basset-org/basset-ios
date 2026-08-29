import BassetEntityComponent

extension Entity {
    var componentIDs: Set<Component.ID> {
        Set(components.map(\.id))
    }
}
