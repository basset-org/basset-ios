import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Foreground/background state, tracked from `start` rather than instrument activation.
enum ApplicationPresence {
    private static let foreground: AtomicStatus = .init()
    /// Guards against subscribing twice, which would double-count every transition.
    private static let watching: Mutex<Bool> = .init(false)

    static var isForeground: Bool {
        foreground.isActive
    }

    static var state: String {
        isForeground ? "foreground" : "background"
    }

    /// Called from `start`; subscribes from any thread, reads state on main asynchronously.
    static func capture() {
        let already = watching.withLock { watching -> Bool in
            let seen = watching
            watching = true
            return seen
        }
        guard !already else {
            return
        }

        let center = NotificationCenter.default
        #if canImport(UIKit)
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in foreground.activate() }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in foreground.activate() }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in foreground.deactivate() }

        #elseif canImport(AppKit)
        center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in foreground.activate() }
        center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { _ in foreground.deactivate() }
        #else
        // No UIKit/AppKit: treated as always foreground, or every run reads backgrounded.
        foreground.activate()
        #endif

        if Thread.isMainThread {
            read()
        } else {
            DispatchQueue.main.async { read() }
        }
    }

    private static func read() {
        #if canImport(UIKit)
        // An extension host has no application object; treated as foreground like no-UIKit.
        if HostApplication.shared?.applicationState == .background {
            foreground.deactivate()
        } else {
            foreground.activate()
        }
        #elseif canImport(AppKit)
        if NSApplication.shared.isActive {
            foreground.activate()
        } else {
            foreground.deactivate()
        }
        #endif
    }
}
