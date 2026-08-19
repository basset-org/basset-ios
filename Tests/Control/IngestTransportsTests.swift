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

    /// A custom control host has no configured domain to widen from by default — an exact
    /// match is the only safe fallback, whatever the host's own label count happens to be.
    @Test func aTwoLabelControlHostAlsoRequiresAnExactMatch() {
        let opener = opener(control: "https://basset.dev")
        #expect(opener.hostname("basset.dev") == "basset.dev")
        #expect(opener.hostname("in.basset.dev") == nil)
    }

    /// Guessing a domain out of a control host's own labels can't tell "co.uk" the public
    /// suffix from "mycompany.co.uk" the registrable domain — so nothing is guessed. A control
    /// host that happens to sit one label below a multi-label suffix is exactly as unwidened
    /// as any other, and a tampered control response naming a sibling under that suffix is
    /// refused rather than trusted.
    @Test func aControlHostUnderAMultiLabelPublicSuffixIsNotWidenedWithoutConfiguration() {
        let opener = opener(control: "https://ctrl.co.uk")
        #expect(opener.hostname("ctrl.co.uk") == "ctrl.co.uk")
        #expect(opener.hostname("evil.co.uk") == nil)
        #expect(opener.hostname("in.co.uk") == nil)
    }

    /// `ingestDomain` is how a deployment states the sibling relationship explicitly, rather
    /// than having it inferred from the control host's labels.
    @Test func anExplicitIngestDomainWidensPastAnExactMatch() {
        let opener = opener(
            control: "https://ctrl.mycompany.co.uk",
            ingestDomain: "mycompany.co.uk"
        )
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

    /// IPv6 rides through `URL.host` unbracketed, and the exact-match check works on that
    /// same unbracketed form — this only fails if the two disagree about the shape.
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
