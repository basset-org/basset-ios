import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
/// Touches an attached machine delivered, held weakly so an instrument judging a person's
/// fingers can leave them out. Compiled out of a release build with the rest of attach mode.
public enum SyntheticTouches {
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static let touches: NSHashTable<UITouch> = .weakObjects()

    public static func mark(_ touch: UITouch) {
        lock.withLock { touches.add(touch) }
    }

    static func contains(_ touch: UITouch) -> Bool {
        lock.withLock { touches.contains(touch) }
    }
}
#endif
