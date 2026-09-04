import Foundation
import ObjectiveC

/// A pointer read, never `String(describing:)`: demangling costs milliseconds per new class.
enum RuntimeClassName {
    static func of(_ object: AnyObject) -> String {
        // `classForCoder`, not the isa: KVO's dynamic subclass must not name the reading.
        NSStringFromClass((object as? NSObject)?.classForCoder ?? type(of: object))
    }
}
