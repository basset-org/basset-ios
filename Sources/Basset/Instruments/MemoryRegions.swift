import BassetEntityComponent
import Foundation

/// Owners of the app's memory by kernel tag, every window; `MemoryPressure` adds it on critical.
final class MemoryRegions: Streamable, PlainInstrument {
    static let id: InstrumentID = .memoryRegions

    /// Enough rows to name every owner that matters; the rest of the map is dozens of
    /// tags holding a page or two each.
    static let ceiling = 24
    static let windowSeconds = 5

    private let ledger: Mutex<RegionLedger> = .init(RegionLedger())

    init() {}

    func observe(_ context: Context) {
        context.flush(every: .seconds(Self.windowSeconds), into: .process) { [weak self] out, _ in
            self?.take(into: &out)
        }
    }

    func stopObserving() {}

    private func take(into out: inout Readings) {
        let totals = VMRegionWalk.totalsByTag()
        let rows = ledger.withLock { $0.advance(to: totals) }
        rows.write(into: &out, ceiling: Self.ceiling)
    }
}

/// Deltas need the previous walk; the ledger is that memory, one walk deep.
struct RegionLedger {
    struct Row: Equatable {
        let totals: VMRegionTotals
        let dirtyDeltaBytes: Int64

        var weight: UInt64 {
            max(totals.dirtyBytes, dirtyDeltaBytes.magnitude)
        }
    }

    struct Table: Equatable {
        let rows: [Row]

        var residentBytes: UInt64 {
            rows.reduce(0) { $0 &+ $1.totals.residentBytes }
        }

        var dirtyBytes: UInt64 {
            rows.reduce(0) { $0 &+ $1.totals.dirtyBytes }
        }

        var compressedBytes: UInt64 {
            rows.reduce(0) { $0 &+ $1.totals.compressedBytes }
        }

        var regionCount: UInt32 {
            rows.reduce(0) { $0 &+ $1.totals.regionCount }
        }

        /// The process row leads with totals; owners follow ordered by the larger of dirty
        /// bytes and the change in them, so a release competes for a row on its size.
        func write(into out: inout Readings, ceiling: Int) {
            out.put(.residentBytes(residentBytes))
            out.put(.dirtyBytes(dirtyBytes))
            out.put(.compressedBytes(compressedBytes))
            out.put(.regionCount(regionCount))

            let named = rows
                .filter { $0.totals.residentBytes > 0 || $0.dirtyDeltaBytes != 0 }
                .sorted { $0.weight > $1.weight }
            for row in named.prefix(ceiling) {
                out.also(.memoryRegion) { region in
                    region.put(.memoryTag(VMTag.name(row.totals.tag)))
                    region.put(.residentBytes(row.totals.residentBytes))
                    region.put(.dirtyBytes(row.totals.dirtyBytes))
                    region.put(.compressedBytes(row.totals.compressedBytes))
                    region.put(.regionCount(row.totals.regionCount))
                    region.put(.dirtyDeltaBytes(row.dirtyDeltaBytes))
                }
            }
            guard named.count > ceiling else {
                return
            }

            out.also(.memoryRegion) { rest in
                rest.put(.memoryTag("other"))
                rest.put(.mechanismStatus("truncated: \(named.count - ceiling) more owners"))
            }
        }
    }

    private var previous: [UInt32: UInt64] = [:]

    mutating func advance(to totals: [VMRegionTotals]) -> Table {
        var rows = totals.map { current in
            Row(
                totals: current,
                dirtyDeltaBytes: Int64(bitPattern: current.dirtyBytes)
                    &- Int64(bitPattern: previous[current.tag] ?? 0)
            )
        }
        let seen = Set(totals.map(\.tag))
        for (tag, dirty) in previous where !seen.contains(tag) && dirty > 0 {
            rows.append(Row(
                totals: VMRegionTotals(
                    tag: tag,
                    residentBytes: 0,
                    dirtyBytes: 0,
                    compressedBytes: 0,
                    regionCount: 0
                ),
                dirtyDeltaBytes: 0 &- Int64(bitPattern: dirty)
            ))
        }
        previous = Dictionary(totals.map { ($0.tag, $0.dirtyBytes) }, uniquingKeysWith: { $1 })
        return Table(rows: rows)
    }
}
