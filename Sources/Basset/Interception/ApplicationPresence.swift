import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether the app is in front, tracked from the moment `start` runs rather than
/// from the moment an instrument activates.
///
/// `applicationState` reads only on the main thread, and an instrument
/// activating on the runner's queue cannot ask for it — least of all a hang
/// instrument, which exists because the main thread is the surface that cannot
/// be asked anything. Assuming foreground instead is what a request activating
/// during a background launch paid for: lifecycle labelled the state wrongly for
/// as long as the app stayed behind, and background work was reported as a
/// main-thread hang, which raised a fault and captured every thread in the
/// process for a launch that was behaving correctly.
///
/// Inactive until told otherwise. The conservative direction: an instrument that
/// suppresses a reading in the background reports nothing, where one that
/// invents foreground reports something false.
enum ApplicationPresence {
    private static let foreground: AtomicStatus = .init()
    /// Subscribing twice would count every transition twice. `start` guards
    /// itself, so this is for the second caller that does not exist yet.
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var watching = false

    static var isForeground: Bool {
        foreground.isActive
    }

    static var state: String {
        isForeground ? "foreground" : "background"
    }

    /// Called from `start`, before any request can arrive. Subscribing works from
    /// any thread; the first read needs main, and takes it asynchronously rather
    /// than blocking the caller's launch.
    static func capture() {
        lock.lock()
        let already = watching
        watching = true
        lock.unlock()
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
        // Neither framework: a process with no application to be in front of is
        // always in front. Left inactive, `concurrency.mainThreadHang` reports
        // nothing at all and `lifecycle.lastRunEnded` calls every run
        // backgrounded — a whole platform reading as an app nobody opened.
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
        if UIApplication.shared.applicationState == .background {
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
