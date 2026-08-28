import Basset
import Foundation
import Network

// Linking this module is what lets a developer's machine reach an app on the same
// desk. It is a separate product so a shipped build cannot link it by accident, and
// every symbol is compiled away outside a debug build.
#if DEBUG
public enum BassetAttached {
    public enum Failure: Error, CustomStringConvertible {
        case noFreePort(from: UInt16, tried: Int)
        case documentTooLong(Int)

        public var description: String {
            switch self {
            case .noFreePort(let from, let tried):
                "no free port for the attached listener in \(from)..<\(from + UInt16(tried))"
            case .documentTooLong(let bytes):
                "a desired state of \(bytes) bytes is a caller that has lost sync"
            }
        }
    }

    /// Walked upward until one binds, because two apps may be attached at once and a
    /// port left in TIME_WAIT by a previous run is common.
    public static let firstPort: UInt16 = 30950
    public static let portsToTry = 10

    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var link: AttachedLink?

    /// Listens on loopback for a machine to dial in. Listening is the direction that
    /// works over a cable — usbmux can open a connection to a port on the device and
    /// has no way to do the reverse — and it is also the direction iOS asks no local
    /// network permission for.
    /// Never throws: this runs while an app is launching, and a diagnostics tool that
    /// can stop that is worse than one that does not run. Returns nil, having said
    /// why, when no port was free.
    @discardableResult
    public static func listen() -> UInt16? {
        do {
            let opened = try AttachedLink()
            lock.withLock {
                link?.stop()
                link = opened
            }
            return opened.port
        } catch {
            NSLog("[basset] not listening for an attached machine: \(error)")
            return nil
        }
    }

    public static func stop() {
        lock.withLock {
            link?.stop()
            link = nil
        }
    }
}
#endif
