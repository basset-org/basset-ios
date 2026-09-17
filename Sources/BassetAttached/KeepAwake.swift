import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
@MainActor
enum KeepAwake {
    private static var appsOwnValue: Bool?

    static var isHeld: Bool {
        appsOwnValue != nil
    }

    static func hold(_ wanted: Bool) {
        if wanted {
            if appsOwnValue == nil {
                appsOwnValue = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let restored = appsOwnValue {
            UIApplication.shared.isIdleTimerDisabled = restored
            appsOwnValue = nil
        }
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
