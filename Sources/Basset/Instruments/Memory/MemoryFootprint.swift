import BassetECS
import Foundation

final class MemoryFootprint: SnapshotInstrument {
    static let id: InstrumentWireID = .memoryFootprint
    static let entity = Entity.WireID.process

    init() {}

    func reading(_ out: inout Readings) {
        MemoryLedger.read()?.write(into: &out)
    }
}
