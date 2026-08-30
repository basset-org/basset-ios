import Basset
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    private static let rebindQueue: DispatchQueue = .init(label: "dev.basset.attached.rebind")
    private nonisolated(unsafe) static var link: AttachedLink?
    private nonisolated(unsafe) static var isListening = false
    private nonisolated(unsafe) static var watchingForeground = false
    private nonisolated(unsafe) static var backgrounded = false
    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []

    /// Listens on loopback for a machine to connect. Listening is the direction that
    /// works over a cable — usbmux can open a connection to a port on the device and
    /// has no way to do the reverse — and it is also the direction iOS asks no local
    /// network permission for. Rebinds on every return to foreground, since a suspended
    /// app stops accepting and nothing here can tell whether the old listener's socket
    /// survived the suspension.
    /// Never throws: this runs while an app is launching, and a diagnostics tool that
    /// can stop that is worse than one that does not run. Returns nil, having said
    /// why, when no port was free.
    @discardableResult
    public static func listen() -> UInt16? {
        lock.withLock { isListening = true }
        watchForeground()
        return bind()
    }

    public static func stop() {
        let removed = lock.withLock { () -> [NSObjectProtocol] in
            isListening = false
            watchingForeground = false
            backgrounded = false
            link?.stop()
            link = nil
            let existing = observers
            observers = []
            return existing
        }

        let center = NotificationCenter.default
        for observer in removed {
            center.removeObserver(observer)
        }
    }

    @discardableResult
    private static func bind() -> UInt16? {
        guard lock.withLock({ isListening }) else {
            return nil
        }

        do {
            let opened = try AttachedLink()
            let published = lock.withLock { () -> AttachedLink? in
                guard isListening else {
                    return nil
                }

                link?.stop()
                link = opened
                return opened
            }
            guard let published else {
                opened.stop()
                return nil
            }

            return published.port
        } catch {
            NSLog("[basset] not listening for an attached machine: \(error)")
            return nil
        }
    }

    private static func watchForeground() {
        let already = lock.withLock { () -> Bool in
            let seen = watchingForeground
            watchingForeground = true
            return seen
        }
        guard !already else {
            return
        }

        let center = NotificationCenter.default
        var installed = [NSObjectProtocol]()
        #if canImport(UIKit)
        installed.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in lock.withLock { backgrounded = true } })
        installed.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in rebindIfBackgrounded() })
        #elseif canImport(AppKit)
        installed.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { _ in lock.withLock { backgrounded = true } })
        installed.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in rebindIfBackgrounded() })
        #endif

        lock.withLock { observers = installed }
    }

    /// Off the notification's own thread — usually the main thread, and `bind()` can
    /// block for seconds walking candidate ports.
    private static func rebindIfBackgrounded() {
        let was = lock.withLock { () -> Bool in
            let seen = backgrounded
            backgrounded = false
            return seen
        }
        guard was else {
            return
        }

        rebindQueue.async {
            _ = bind()
        }
    }
}
#endif
