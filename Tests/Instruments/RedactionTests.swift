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
            // The token alphabet includes base64url punctuation.
            "https://api.example.com/reset/aB3x-K9z_Q7mPL5v2":
                "https://api.example.com/reset/:id",
            // A JWT sitting in a path carries dots between its parts.
            "https://api.example.com/verify/eyJhbGc.eyJzdWI5.Q7mPL5v2":
                "https://api.example.com/verify/:id",
        ]

        for (given, expected) in cases {
            #expect(Redaction.url(URL(string: given)) == expected)
        }
    }

    @Test func aSegmentLabeledByTheCollectionBeforeItIsRedactedRegardlessOfShape() {
        let cases = [
            "https://api.example.com/profile/jsmith123": "https://api.example.com/profile/:id",
            "https://api.example.com/u/alice": "https://api.example.com/u/:id",
            "https://api.example.com/customers/customer42": "https://api.example.com/customers/:id",
        ]

        for (given, expected) in cases {
            #expect(Redaction.url(URL(string: given)) == expected)
        }
    }

    /// Over-redaction costs the reader the shape of the request.
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

    /// An app logging a secret as public leaks it verbatim unless the message is scrubbed.
    @Test func tokenShapedRunsLeaveALogMessage() {
        let cases = [
            "login failed for jeff@example.com": "login failed for :id",
            "charging card 4111111111111111 now": "charging card :id now",
            // A card number is often logged in its printed, space-grouped form.
            "charging card 4111 1111 1111 1111 now": "charging card :id now",
            // The token alphabet includes base64url punctuation.
            "bearer aB3x-K9z_Q7mPL5v2 expired": "bearer :id expired",
            "order 3f2504e0-4f89-11d3-9a0c-0305e82c3301 declined":
                "order :id declined",
        ]

        for (given, expected) in cases {
            #expect(Redaction.message(given) == expected)
        }
    }

    @Test func aRunLabeledByTheWordBeforeItIsRedactedRegardlessOfShape() {
        let cases = [
            "Authorization tok_ABC123": "Authorization :id",
            "Authorization abcdefghijklmnopq": "Authorization :id",
            "bearer abc": "bearer :id",
            "api key AB12 rotated": "api key :id rotated",
            "secret shh now rotate it": "secret :id now rotate it",
        ]

        for (given, expected) in cases {
            #expect(Redaction.message(given) == expected)
        }
    }

    @Test func aLabelAttachedByAnEqualsSignIsRedactedRegardlessOfShape() {
        let cases = [
            "token=abc rotated": "token=:id rotated",
            "key=AB12 now": "key=:id now",
            "sent bearer=xyz today": "sent bearer=:id today",
        ]

        for (given, expected) in cases {
            #expect(Redaction.message(given) == expected)
        }
    }

    /// Over-redaction costs the reader the fault — ordinary words and short ids stay.
    @Test func aplainLogMessageKeepsItsWords() {
        let kept = [
            "the network connection was lost",
            "retry 3 of 5 timed out",
            // Spaced four-digit groups that are not a card stay legible.
            "logged years 2020 2021 2022 2023 here",
        ]

        for message in kept {
            #expect(Redaction.message(message) == message)
        }
    }
}
