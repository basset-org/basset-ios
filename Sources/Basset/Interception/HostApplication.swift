#if canImport(UIKit)
import UIKit

/// `UIApplication.shared` is unavailable inside app extensions, so it is reached by
/// key and never from an `.appex` bundle; without an application this reads nil, not raising.
enum HostApplication {
    static var shared: UIApplication? {
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            return nil
        }

        return UIApplication.value(forKey: "sharedApplication") as? UIApplication
    }
}
#endif
