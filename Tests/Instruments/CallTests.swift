@testable import Basset
import Foundation
import ObjectiveC
import Testing

struct ProviderActionsTests {
    private final class EmptyDelegate: NSObject {}

    /// CallKit isn't loaded on every host this runs on; the guard is what's under test there.
    @Test func relevantOnceTheAppHasSetADelegateOnACXProvider() {
        let registries = Registries()
        #expect(ProviderActions.relevance(registries) == .notRelevant)

        guard let provider = objc_getClass(ProviderActions.providerClassName) as? AnyClass else {
            return
        }

        registries.delegates(ObjectIdentifier(provider)).add(EmptyDelegate.self)
        #expect(ProviderActions.relevance(registries) == .relevant)
    }
}
