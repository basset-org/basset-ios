@testable import Basset
import Foundation
import Testing

#if os(iOS)
/// The untouched TLS floor varies by release — iOS 18 reports TLS 1.0, not `.TLSv12`.
struct SessionConfigurationTests {
    /// Ephemeral is the baseline itself, so it is read but not asserted against here.
    @Test
    func everyConfigurationKindCarriesTheSameUntouchedFloor() {
        #expect(
            URLSessionConfiguration.default.tlsMinimumSupportedProtocolVersion
                == SessionConfiguration.untouchedTLSFloor
        )
        #expect(
            URLSessionConfiguration
                .background(withIdentifier: "dev.basset.tests.tlsFloor")
                .tlsMinimumSupportedProtocolVersion
                == SessionConfiguration.untouchedTLSFloor
        )
    }

    @Test
    func aFloorTheAppMovedIsDistinguishableFromAnUntouchedOne() {
        let moved: tls_protocol_version_t =
            if SessionConfiguration.untouchedTLSFloor == .TLSv13 {
                .TLSv12
            } else {
                .TLSv13
            }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = moved

        #expect(
            configuration.tlsMinimumSupportedProtocolVersion
                != SessionConfiguration.untouchedTLSFloor
        )
    }
}
#endif
