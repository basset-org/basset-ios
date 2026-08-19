@testable import Basset
import Foundation
import Testing

/// A control channel a trusted MITM tampered with must not be able to point ingest anywhere it
/// likes.
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

    /// Two labels alone can't say whether the control host is a bare registrable domain or
    /// itself sits under a public suffix — without a public-suffix list, only an exact match
    /// is safe, so a subdomain that a real deployment might legitimately want is refused too.
    @Test func aTwoLabelControlHostAlsoRequiresAnExactMatch() {
        let opener = opener(control: "https://basset.dev")
        #expect(opener.hostname("basset.dev") == "basset.dev")
        #expect(opener.hostname("in.basset.dev") == nil)
    }

    /// Peeling one label off a control host under a multi-label public suffix still lands on
    /// the integrator's own domain, not the bare suffix — "co.uk" alone never becomes the anchor.
    @Test func aSubdomainUnderAMultiLabelPublicSuffixIsBoundedToTheIntegratorsDomain() {
        let opener = opener(control: "https://ctrl.mycompany.co.uk")
        #expect(opener.hostname("in.mycompany.co.uk") == "in.mycompany.co.uk")
        #expect(opener.hostname("evil.co.uk") == nil)
    }

    /// An IP literal has no label structure to widen from — only the exact address will do.
    @Test func anIpLiteralControlHostRequiresAnExactMatch() {
        let opener = opener(control: "https://10.0.0.5")
        #expect(opener.hostname("10.0.0.5") == "10.0.0.5")
        #expect(opener.hostname("10.0.0.5.evil.com") == nil)
        #expect(opener.hostname("evil.0.5") == nil)
    }

    @Test func nonHostnameCharactersAreRejectedRegardlessOfDomain() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("in.basset.dev/../attacker.com") == nil)
    }

    private func opener(control: String) -> IngestTransports {
        IngestTransports(config: Config(apiKey: "key", control: URL(string: control)!))
    }
}
