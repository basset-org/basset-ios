@testable import Basset
import Foundation
import Testing

struct IngestTransportsTests {
    @Test func aSubdomainOfTheControlDomainIsAccepted() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("in.basset.dev") == "in.basset.dev")
    }

    @Test func theControlDomainItselfIsAccepted() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("basset.dev") == "basset.dev")
    }

    @Test func anUnrelatedDomainIsRejected() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("attacker.example.com") == nil)
    }

    @Test func aDomainMerelySuffixedByTheControlDomainIsRejected() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("notbasset.dev") == nil)
    }

    @Test func aSingleLabelControlHostRequiresAnExactMatch() {
        let opener = opener(control: "https://localhost")
        #expect(opener.hostname("localhost") == "localhost")
        #expect(opener.hostname("evil.localhost") == nil)
    }

    @Test func aTwoLabelControlHostAlsoRequiresAnExactMatch() {
        let opener = opener(control: "https://basset.dev")
        #expect(opener.hostname("basset.dev") == "basset.dev")
        #expect(opener.hostname("in.basset.dev") == nil)
    }

    @Test func aControlHostUnderAMultiLabelPublicSuffixIsNotWidenedWithoutConfiguration() {
        let opener = opener(control: "https://ctrl.co.uk")
        #expect(opener.hostname("ctrl.co.uk") == "ctrl.co.uk")
        #expect(opener.hostname("evil.co.uk") == nil)
        #expect(opener.hostname("in.co.uk") == nil)
    }

    @Test func anExplicitIngestDomainWidensPastAnExactMatch() {
        let opener = opener(
            control: "https://ctrl.mycompany.co.uk",
            ingestDomain: "mycompany.co.uk"
        )
        #expect(opener.hostname("in.mycompany.co.uk") == "in.mycompany.co.uk")
        #expect(opener.hostname("evil.co.uk") == nil)
    }

    @Test func anIpLiteralControlHostRequiresAnExactMatch() {
        let opener = opener(control: "https://10.0.0.5")
        #expect(opener.hostname("10.0.0.5") == "10.0.0.5")
        #expect(opener.hostname("10.0.0.5.evil.com") == nil)
        #expect(opener.hostname("evil.0.5") == nil)
    }

    @Test func anIpv6LiteralControlHostRequiresAnExactMatch() {
        let opener = opener(control: "https://[::1]")
        #expect(opener.hostname("::1") == "::1")
        #expect(opener.hostname("::2") == nil)
    }

    @Test func nonHostnameCharactersAreRejectedRegardlessOfDomain() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("in.basset.dev/../attacker.com") == nil)
    }

    private func opener(control: String, ingestDomain: String? = nil) -> IngestTransports {
        IngestTransports(config: Config(
            apiKey: "key",
            control: URL(string: control)!,
            ingestDomain: ingestDomain
        ))
    }
}
