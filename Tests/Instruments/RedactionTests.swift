@testable import Basset
import Foundation
import Testing

struct RedactionTests {
    @Test func thequeryIsDroppedWhole() {
        #expect(
            Redaction
                .url(URL(string: "https://api.example.com/search?q=cancer&t=ey.j")) ==
                "https://api.example.com/search"
        )
    }

    @Test func credentialsInTheAuthorityNeverSurvive() {
        #expect(
            Redaction.url(URL(string: "https://user:secret@api.example.com/health")) ==
                "https://api.example.com/health"
        )
    }

    @Test func identifierShapedSegmentsAreReplaced() {
        let cases = [
            "https://api.example.com/users/48213/orders":
                "https://api.example.com/users/:id/orders",
            "https://api.example.com/o/3f2504e0-4f89-11d3-9a0c-0305e82c3301":
                "https://api.example.com/o/:id",
            // An address in a path is the person, spelled out.
            "https://api.example.com/users/a.person@example.com":
                "https://api.example.com/users/:id",
            // A reset token is a credential sitting in a path.
            "https://api.example.com/reset/aB3xK9zQ7mW2pL5v":
                "https://api.example.com/reset/:id",
        ]

        for (given, expected) in cases {
            #expect(Redaction.url(URL(string: given)) == expected)
        }
    }

    /// Over-redaction costs the reader the shape of the request, which is the
    /// whole point of keeping the path at all.
    @Test func ordinaryPathWordsKeepTheirShape() {
        let kept = [
            "https://api.example.com/v2/payment-methods/default",
            "https://api.example.com/organizations/settings",
        ]

        for url in kept {
            #expect(Redaction.url(URL(string: url)) == url)
        }
    }

    @Test func aurlWithNoHostRedactsToNothing() {
        #expect(Redaction.url(URL(string: "/relative/path")) == "")
        #expect(Redaction.url(nil) == "")
    }
}
