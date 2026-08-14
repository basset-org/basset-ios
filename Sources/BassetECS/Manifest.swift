public struct AdvertisedInstrument: Equatable, Sendable {
    public let id: UInt16
    public let emits: [UInt16]

    public init(id: UInt16, emits: [UInt16]) {
        self.id = id
        self.emits = emits
    }
}
