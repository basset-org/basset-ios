@testable import Basset
import BassetECS
import Testing

struct CameraTests {
    /// The catalog states this default in prose, and nothing else checks the two agree.
    @Test func callersAreReportedUnlessARequestTurnsThemOff() {
        #expect(CameraSessionConfiguration.defaultConfig.callers)
    }

    @Test func theCatalogOffersTheKeyThatTurnsThemOff() {
        let declared = InstrumentID.cameraSessionConfiguration.metadata.config
        #expect(declared.contains { $0.key == "callers" })
    }
}
