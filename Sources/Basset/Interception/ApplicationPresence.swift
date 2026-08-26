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

    private static let rotation: Mutex<String> = .init("unknown")

    static var isForeground: Bool {
        foreground.isActive
    }

    static var state: String {
        isForeground ? "foreground" : "background"
    }

    /// What the interface is showing, not how the phone is being held. `UIDevice`'s own
    /// orientation reads `unknown` until someone calls
    /// `beginGeneratingDeviceOrientationNotifications`, which powers the accelerometer and is
    /// reference counted — a library calling it can leave an app's own `end` unbalanced.
    static var orientation: String {
        #if canImport(UIKit)
        // Read here when the caller is already on main: the cached value is refreshed from a
        // main-queued observer, which has not run yet inside a synchronous notification block.
        if Thread.isMainThread, let read = readOrientation() {
            rotation.withLock { $0 = read }
            return read
        }
        #endif

        return rotation.withLock { $0 }
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

        #if canImport(UIKit)
        // Observed but never started: an app already generating them gets live rotation for
        // nothing, and one that is not still has the value read on every presence change.
        center.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in read() }
        #endif

        if Thread.isMainThread {
            read()
        } else {
            DispatchQueue.main.async { read() }
        }
    }

    private static func read() {
        #if canImport(UIKit)
        // Kept when there is nothing to read: backgrounding leaves no active scene, and the
        // last orientation the app was in is a better answer than none.
        if let read = readOrientation() {
            rotation.withLock { $0 = read }
        }
        #endif
        readPresence()
    }

    #if canImport(UIKit)
    private static func readOrientation() -> String? {
        // A backgrounded scene in a multi-window app answers with its own last orientation.
        let scene = HostApplication.shared?
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else {
            return nil
        }

        return switch scene.interfaceOrientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: nil
        }
    }
    #endif

    private static func readPresence() {
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
