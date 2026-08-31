@testable import Basset
import Foundation
import ObjectiveC
import Testing

struct DelegateSilenceTests {
    private final class EmptyDelegate: NSObject {}

    /// Resolving the class is inert; only constructing a real manager raises the prompt.
    @Test func relevantOnceTheAppHasSetADelegateOnALocationManager() {
        let registries = Registries()
        #expect(DelegateSilence.relevance(registries) == .notRelevant)

        guard let manager = objc_getClass(DelegateSilence.managerClassName) as? AnyClass else {
            return
        }

        registries.delegates(ObjectIdentifier(manager)).add(EmptyDelegate.self)
        #expect(DelegateSilence.relevance(registries) == .relevant)
    }
}
