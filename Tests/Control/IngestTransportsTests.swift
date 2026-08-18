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

    @Test func nonHostnameCharactersAreRejectedRegardlessOfDomain() {
        let opener = opener(control: "https://ctrl.basset.dev")
        #expect(opener.hostname("in.basset.dev/../attacker.com") == nil)
    }

    private func opener(control: String) -> IngestTransports {
        IngestTransports(config: Config(apiKey: "key", control: URL(string: control)!))
    }
}
