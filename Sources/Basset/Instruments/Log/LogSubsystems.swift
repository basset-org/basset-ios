import BassetECS
import Foundation

/// Who is logging inside this process, and how much.
///
/// The question that comes before every other one in this domain. Nobody can ask
/// for a framework's complaints without knowing it is complaining, and no list of
/// subsystems exists anywhere to consult — an app links whatever it links, and
/// each of those logs under names nobody published. This reads the process and
/// says what is actually there.
///
/// Deliberately says nothing about *what* was logged. Volume and severity per
/// subsystem is a map; `log.faults` is what to do with it.
final class LogSubsystems: StreamingInstrument {
    static let id: InstrumentWireID = .logSubsystems
    static let entity = Entity.WireID.logRecord

    private static let sourcesPerFlush = 32

    private let reader: LogStoreReader = .init(subsystems: [])

    init() {}

    static func write(
        _ traffic: LogTraffic,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        for (index, source) in traffic.sources.enumerated() {
            if index == 0 {
                put(source, over: window, into: &out)
                continue
            }
            out.also(entity) { sibling in put(source, over: window, into: &sibling) }
        }

        guard traffic.omitted > 0 else {
            return
        }

        out.also(entity) { sibling in
            sibling.put(.windowNanoseconds(window.nanoseconds))
            sibling.put(.occurrenceCount(traffic.total))
            sibling.put(.mechanismStatus("truncated: \(traffic.omitted) more"))
        }
    }

    private static func put(
        _ source: LogTraffic.Source,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.logSubsystem(source.subsystem))
        out.put(.logCategory(source.category))
        out.put(.occurrenceCount(source.count))
        // How many of that count were errors or faults. Carried apart from the
        // total because a subsystem logging ten thousand notices and one logging
        // a single fault are opposite findings that a single number merges.
        if source.diagnostics > 0 {
            out.put(.detail("diagnostics: \(source.diagnostics)"))
        }
    }

    func observe(_ context: Context) {
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records):
                let traffic = LogTraffic(records, ceiling: Self.sourcesPerFlush)
                guard !traffic.isEmpty else {
                    return
                }

                Self.write(traffic, over: window, into: &out)
            }
        }
    }

    func stopObserving() {}
}
