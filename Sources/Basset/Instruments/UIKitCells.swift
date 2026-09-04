import BassetEntityComponent
import Foundation
import ObjectiveC

#if canImport(UIKit)
import UIKit
#endif

/// One timed call into a data source's cell provider, materialized only past the threshold.
struct CellCall: Equatable {
    let dataSourceClass: String
    let selector: String
    let cellClass: String
    let reuseIdentifier: String?
    let section: UInt32?
    let item: UInt32?
    let nanoseconds: UInt64
}

/// The slowest over-threshold call per data source class this window; counts live in the tally.
struct CellConfigurationLedger: Equatable {
    struct Key: Hashable {
        let dataSourceClass: String
        let selector: String
    }

    private(set) var slowest: [Key: CellCall] = [:]

    var isEmpty: Bool {
        slowest.isEmpty
    }

    mutating func record(_ call: CellCall) {
        let key = Key(dataSourceClass: call.dataSourceClass, selector: call.selector)
        if let held = slowest[key], held.nanoseconds >= call.nanoseconds {
            return
        }

        slowest[key] = call
    }

    mutating func take() -> [Key: CellCall] {
        defer { slowest = [:] }
        return slowest
    }
}

/// Count, total and peak for one data source class — the only work a fast cell pays for.
struct CellCounters {
    static let calls: TallySlot = .first
    static let totalNanoseconds: TallySlot = .second
    static let peakNanoseconds: TallySlot = .third

    let key: CellConfigurationLedger.Key
    let tally: Tally = .init(slots: 3)

    func count(_ elapsed: UInt64) {
        tally.add(Self.calls)
        tally.add(Self.totalNanoseconds, elapsed)
        tally.raise(Self.peakNanoseconds, to: elapsed)
    }

    /// Drains the window; nil when no call landed in it.
    func take(slowest: CellCall?) -> CellWindowRow? {
        let calls = tally.take(Self.calls)
        let total = tally.take(Self.totalNanoseconds)
        let peak = tally.take(Self.peakNanoseconds)
        guard calls > 0 else {
            return nil
        }

        return CellWindowRow(
            key: key,
            calls: calls,
            totalNanoseconds: total,
            peakNanoseconds: peak,
            slowest: slowest
        )
    }
}

struct CellWindowRow: Equatable {
    let key: CellConfigurationLedger.Key
    let calls: UInt64
    let totalNanoseconds: UInt64
    let peakNanoseconds: UInt64
    let slowest: CellCall?

    func write(over window: Context.FlushWindow, into out: inout Readings) {
        out.put(.delegateClass(key.dataSourceClass))
        out.put(.methodName(key.selector))
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.occurrenceCount(calls))
        out.put(.totalNanoseconds(totalNanoseconds))
        out.put(.peakNanoseconds(peakNanoseconds))
        if let slowest {
            CellConfiguration.describe(slowest, into: &out)
        }
    }
}

/// Times `cellForItemAt:`/`cellForRowAt:` per data source class; past the threshold a call gets
/// its own reading with the stack walked while it was still inside.
final class CellConfiguration: Streamable, Configurable, LoadTimeInstall, @unchecked Sendable {
    struct Config: Codable, Sendable {
        let thresholdMs: Int
    }

    private struct State {
        var ledger: CellConfigurationLedger = .init()
        var inFlight: InFlightTokens = .init()
        var counters: [CellCounters] = []
        var followed: [(DelegateClasses, Int)] = []
    }

    static let id: InstrumentID = .cellConfiguration
    /// Half a frame at 60 Hz — a cell that costs more than this cannot be laid out and drawn
    /// inside the same frame it was asked for.
    static let defaultConfig: Config = .init(thresholdMs: 8)

    private static let minimumThresholdMs = 1
    private static let maximumThresholdMs = 5000

    private static let collectionViewClassName = "UICollectionView"
    private static let tableViewClassName = "UITableView"
    private static let setDataSource: Selector = .init("setDataSource:")
    private static let cellForItem: Selector = .init("collectionView:cellForItemAtIndexPath:")
    private static let cellForRow: Selector = .init("tableView:cellForRowAtIndexPath:")

    let thresholdNanoseconds: UInt64

    private let guarded: Mutex<State> = .init(State())
    private let watchdog: CallbackWatchdog = .init(name: "dev.basset.cell.watchdog")

    init(config: Config) {
        let clampedMs = min(
            max(config.thresholdMs, Self.minimumThresholdMs),
            Self.maximumThresholdMs
        )
        thresholdNanoseconds = UInt64(clampedMs) * 1000000
    }

    static func relevance(_ registries: Registries) -> Relevance {
        registries.hasDelegate(on: collectionViewClassName)
            || registries.hasDelegate(on: tableViewClassName)
            ? .relevant
            : .notRelevant
    }

    /// At load: a data source set before activation would otherwise never be seen.
    static func installAtLoad(_ hooks: HookTable) {
        for name in [collectionViewClassName, tableViewClassName] {
            guard let owner = objc_getClass(name) as? AnyClass else {
                continue
            }

            hooks.trackDelegateClass(at: setDataSource, on: owner)
        }
    }

    static func notWalkedStatus(
        sanitizerLoaded: Bool = ThreadWalker.isThreadSanitizerLoaded
    ) -> String {
        sanitizerLoaded
            ? "stack not walked: a thread sanitizer is loaded"
            : "stack not walked: the configuration returned before the watchdog reached it"
    }

    static func describe(_ call: CellCall, into out: inout Readings) {
        out.put(.runtimeClassName(call.cellClass))
        if let reuseIdentifier = call.reuseIdentifier {
            out.put(.reuseIdentifier(reuseIdentifier))
        }
        if let section = call.section {
            out.put(.sectionIndex(section))
        }
        if let item = call.item {
            out.put(.itemIndex(item))
        }
    }

    private static func call(
        _ key: CellConfigurationLedger.Key,
        cell: AnyObject?,
        indexPath: AnyObject?,
        elapsed: UInt64
    ) -> CellCall {
        let path = indexPath as? NSIndexPath
        return CellCall(
            dataSourceClass: key.dataSourceClass,
            selector: key.selector,
            cellClass: cell.map { RuntimeClassName.of($0) } ?? "",
            reuseIdentifier: reuseIdentifier(of: cell),
            section: path.map { UInt32(clamping: $0.section) },
            item: path.map { UInt32(clamping: $0.item) },
            nanoseconds: elapsed
        )
    }

    private static func reuseIdentifier(of cell: AnyObject?) -> String? {
        #if canImport(UIKit)
        if let collectionCell = cell as? UICollectionReusableView {
            return collectionCell.reuseIdentifier
        }
        if let tableCell = cell as? UITableViewCell {
            return tableCell.reuseIdentifier
        }
        #endif
        return nil
    }

    func observe(_ context: Context) {
        watchdog.start()
        follow(Self.collectionViewClassName, selector: Self.cellForItem, context)
        follow(Self.tableViewClassName, selector: Self.cellForRow, context)

        context.flush(every: .seconds(1), into: .cellProvider) { [weak self] out, window in
            guard let self else {
                return
            }

            let (counters, slowest) = self.guarded.withLock { ($0.counters, $0.ledger.take()) }
            let rows = counters.compactMap { $0.take(slowest: slowest[$0.key]) }
                .sorted { $0.totalNanoseconds > $1.totalNanoseconds }
            guard let first = rows.first else {
                return
            }

            first.write(over: window, into: &out)
            for row in rows.dropFirst() {
                out.also(out.entity) { additional in
                    row.write(over: window, into: &additional)
                }
            }
        }
    }

    func stopObserving() {
        let followed = guarded.withLock { state -> [(DelegateClasses, Int)] in
            defer { state = State() }
            return state.followed
        }
        for (classes, token) in followed {
            classes.stopFollowing(token)
        }
        watchdog.stop()
    }

    private func follow(_ ownerName: String, selector: Selector, _ context: Context) {
        guard let owner = objc_getClass(ownerName) as? AnyClass else {
            return
        }

        let classes = context.registries.delegates(ObjectIdentifier(owner))
        let token = classes.attachAndFollow { [weak self] dataSourceClass in
            self?.watch(dataSourceClass, selector: selector, context)
        }
        guarded.withLock { $0.followed.append((classes, token)) }
    }

    private func watch(_ dataSourceClass: AnyClass, selector: Selector, _ context: Context) {
        guard class_getInstanceMethod(dataSourceClass, selector) != nil else {
            return
        }

        let counters = CellCounters(key: .init(
            dataSourceClass: NSStringFromClass(dataSourceClass),
            selector: NSStringFromSelector(selector)
        ))
        guarded.withLock { $0.counters.append(counters) }
        let hot = context.hotPath
        _ = context.swizzle.timingFactory(
            dataSourceClass,
            selector,
            takingTwoObjects: (),
            Swizzle.TimedFactoryObserver(
                entering: { [weak self] _, _, _ in
                    guard hot.isActive else {
                        return
                    }

                    self?.entered()
                },
                leaving: { [weak self] _, _, indexPath, made, elapsed in
                    guard hot.isActive else {
                        return
                    }

                    counters.count(elapsed)
                    self?.left(counters.key, cell: made, indexPath: indexPath, elapsed, context)
                }
            )
        )
    }

    private func entered() {
        let token = watchdog.enter(threshold: thresholdNanoseconds)
        let thread = pthread_mach_thread_np(pthread_self())
        if !guarded.withLock({ $0.inFlight.push(token, on: thread) }), let token {
            _ = watchdog.leave(token)
        }
    }

    private func left(
        _ key: CellConfigurationLedger.Key,
        cell: AnyObject?,
        indexPath: AnyObject?,
        _ elapsed: UInt64,
        _ context: Context
    ) {
        let thread = pthread_mach_thread_np(pthread_self())
        let token = guarded.withLock { $0.inFlight.pop(on: thread) }
        let frames = token.flatMap { watchdog.leave($0) }
        guard elapsed >= thresholdNanoseconds else {
            return
        }

        let call = Self.call(key, cell: cell, indexPath: indexPath, elapsed: elapsed)
        guarded.withLock { $0.ledger.record(call) }
        context.emit(.cell) { out in
            out.put(.delegateClass(call.dataSourceClass))
            out.put(.methodName(call.selector))
            out.put(.delegateDurationNanoseconds(call.nanoseconds))
            Self.describe(call, into: &out)
            guard let frames else {
                out.put(.mechanismStatus(Self.notWalkedStatus()))
                return
            }
            guard !frames.isEmpty else {
                out
                    .put(
                        .mechanismStatus(
                            "stack not walked: the walk of the configuring thread was refused"
                        )
                    )
                return
            }

            for frame in frames {
                out.put(.frameAddress(frame))
            }
        }
    }
}
