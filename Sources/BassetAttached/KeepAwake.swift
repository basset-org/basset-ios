import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
@MainActor
enum KeepAwake {
    static var isHeld: Bool {
        UIApplication.shared.isIdleTimerDisabled
    }

    static func hold(_ wanted: Bool) {
        UIApplication.shared.isIdleTimerDisabled = wanted
    }

    nonisolated static func releaseFromAnyThread() {
        DispatchQueue.main.async { hold(false) }
    }
}
#endif

#if DEBUG && !canImport(UIKit)
enum KeepAwake {
    static func releaseFromAnyThread() {}
}
#endif
