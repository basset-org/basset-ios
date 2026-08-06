@testable import Basset
import BassetECS
import Foundation
import Testing

struct TransportSecurityTests {
    /// No dictionary is a posture, not an absence: ATS at its defaults refuses
    /// every plain-http load. Reporting nothing would read as "ATS is not
    /// configured", which is the opposite of what it means.
    @Test func anAbsentDictionaryIsTheStrictDefaultRatherThanNoAnswer() {
        var out = readings()
        TransportSecurity.write(nil, into: &out)

        #expect(rendered(out.sealed(), .arbitraryLoadsAllowed) == "false")
        #expect(out.componentsWritten.contains(.mechanismStatus))
    }

    @Test func arbitraryLoadsAreReportedAsTheBuildSetThem() {
        var permissive = readings()
        TransportSecurity.write(["NSAllowsArbitraryLoads": true], into: &permissive)

        var strict = readings()
        TransportSecurity.write(["NSAllowsArbitraryLoads": false], into: &strict)

        #expect(rendered(permissive.sealed(), .arbitraryLoadsAllowed) == "true")
        #expect(rendered(strict.sealed(), .arbitraryLoadsAllowed) == "false")
    }

    /// The blanket exemptions each widen what the whole app may load, and they
    /// are separate keys from the main switch — an app can refuse arbitrary
    /// loads everywhere except web content, which is the common shape.
    @Test func blanketExemptionsAreNamedRatherThanLeftAsKeys() {
        var out = readings()
        TransportSecurity.write(
            ["NSAllowsArbitraryLoads": false, "NSAllowsArbitraryLoadsInWebContent": true],
            into: &out
        )

        let detail = out.sealed().components.first { $0.id == .detail }?.value.rendered
        #expect(detail == "arbitrary loads allowed in web content")
    }

    @Test func exemptionsThatAreOffAreNotReported() {
        var out = readings()
        TransportSecurity.write(
            ["NSAllowsArbitraryLoadsForMedia": false, "NSAllowsLocalNetworking": false],
            into: &out
        )

        #expect(out.componentsWritten.contains(.detail) == false)
    }

    /// One row per exception domain, because a per-domain TLS floor is how a
    /// single host fails while every other host is fine.
    @Test func eachExceptionDomainBecomesItsOwnRow() {
        var out = readings()
        TransportSecurity.write(
            [
                "NSExceptionDomains": [
                    "legacy.example.com": [
                        "NSExceptionAllowsInsecureHTTPLoads": true,
                        "NSExceptionMinimumTLSVersion": "TLSv1.0",
                    ],
                    "api.example.com": ["NSExceptionAllowsInsecureHTTPLoads": false],
                ],
            ],
            into: &out
        )

        #expect(out.sealedSiblings().count == 2)
        #expect(rendered(out.sealed(), .occurrenceCount) == "2")
        // Sorted, so two captures of one build list the exceptions alike.
        #expect(rendered(out.sealedSiblings()[0], .exceptionDomain) == "api.example.com")
        #expect(rendered(out.sealedSiblings()[1], .minimumTLSVersion) == "TLSv1.0")
    }

    /// A malformed plist must produce a reading rather than a crash — it is a
    /// app's own build, and basset does not get to assume it is well-formed.
    @Test func anExceptionEntryThatIsNotADictionaryIsSurvived() {
        var out = readings()
        TransportSecurity.write(
            ["NSExceptionDomains": ["broken.example.com": "yes"]],
            into: &out
        )

        #expect(out.sealedSiblings().count == 1)
        #expect(rendered(out.sealedSiblings()[0], .insecureLoadsAllowed) == "false")
    }

    private func readings() -> Readings {
        Readings(
            entity: .transportSecurity,
            instrumentName: "network.transportSecurity"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.WireID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
