@testable import Basset
import Foundation
import ObjectiveC
import Testing

struct TileLoadingTests {
    private final class EmptyDelegate: NSObject {}

    /// Resolving the class is inert; only constructing a real map view loads map tiles.
    @Test func relevantOnceTheAppHasSetADelegateOnAMapView() {
        let registries = Registries()
        #expect(TileLoading.relevance(registries) == .notRelevant)

        guard let mapView = objc_getClass(TileLoading.mapViewClassName) as? AnyClass else {
            return
        }

        registries.delegates(ObjectIdentifier(mapView)).add(EmptyDelegate.self)
        #expect(TileLoading.relevance(registries) == .relevant)
    }
}
