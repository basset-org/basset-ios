import BassetECS
import Foundation
#if canImport(Network)
import Network
#endif

/// No interception at all: NWPathMonitor is the API, and it reports every change
/// on its own. Which makes this the cheapest instrument in the domain and the one
/// that answers a question nothing else can — a request that failed on a train
/// failed because the interface moved, and no URLError says so.
final class PathTransitions: StreamingInstrument, @unchecked Sendable {
    #if canImport(Network)
    private struct Snapshot: Equatable {
        let interface: String
        let satisfied: Bool
        let expensive: Bool
        let constrained: Bool
        let reason: String?
    }

    private var monitor: NWPathMonitor?
    private let lock: NSLock = .init()
    private var last: Snapshot?
    #endif

    static let id: InstrumentWireID = .networkPathTransitions
    static let entity = Entity.WireID.networkPath

    init() {}

    #if canImport(Network)
    private static func interface(of path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) {
            return "wifi"
        }
        if path.usesInterfaceType(.cellular) {
            return "cellular"
        }
        if path.usesInterfaceType(.wiredEthernet) {
            return "wired"
        }
        if path.usesInterfaceType(.loopback) {
            return "loopback"
        }
        return "none"
    }

    /// localNetworkDenied is the only public tell that the user declined the
    /// local-network prompt, which otherwise presents as zero peers and no error
    /// at all.
    private static func reason(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: "notAvailable"
        case .cellularDenied: "cellularDenied"
        case .wifiDenied: "wifiDenied"
        case .localNetworkDenied: "localNetworkDenied"
        case .vpnInactive: "vpnInactive"
        @unknown default: "unknown"
        }
    }
    #endif

    func observe(_ context: Context) {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        // Every update, including the first: a capture needs to know what the
        // path was when it started, not only what it changed to.
        // A change, not a callback. NWPathMonitor reports every path change
        // it sees — a route, a DNS server, an interface index — and most of
        // those are invisible in what this emits. A walk produced 24 readings
        // for 3 transitions before this, which is eight times the reading cap
        // spent on saying the same thing.
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            let now = Snapshot(
                interface: Self.interface(of: path),
                satisfied: path.status == .satisfied,
                expensive: path.isExpensive,
                constrained: path.isConstrained,
                reason: path.status == .satisfied
                    ? nil : Self.reason(path.unsatisfiedReason)
            )
            let changed = self.lock.withLock {
                guard now != self.last else {
                    return false
                }

                self.last = now
                return true
            }
            guard changed else {
                return
            }

            context.emit { out in
                out.put(.interfaceKind(now.interface))
                out.put(.pathSatisfied(now.satisfied))
                out.put(.expensiveInterface(now.expensive))
                out.put(.constrainedInterface(now.constrained))
                if let reason = now.reason {
                    out.put(.unsatisfiedReason(reason))
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: QueueLabel.networkPath))
        #endif
    }

    func stopObserving() {
        #if canImport(Network)
        monitor?.cancel()
        monitor = nil
        lock.withLock { last = nil }
        #endif
    }
}
