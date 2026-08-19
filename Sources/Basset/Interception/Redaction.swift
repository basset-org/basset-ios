import Foundation

/// What may leave a URL — query dropped whole; an allow-list is one more thing to keep.
enum Redaction {
    private static let tokenPunctuation: Set<Character> = ["-", "_", ".", "=", "%", "+", "~"]
    private static let credentialLabels: Set<String> = [
        "authorization",
        "bearer",
        "token",
        "key",
        "secret",
    ]
    private static let identityCollectionLabels: Set<String> =
        [
            "u",
            "user",
            "users",
            "profile",
            "profiles",
            "account",
            "accounts",
            "customer",
            "customers",
            "tenant",
            "tenants",
        ]

    static func url(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else {
            return ""
        }

        var previous: String?
        let path = url.pathComponents
            .filter { $0 != "/" }
            .map { component -> String in
                let labeled = previous
                    .map { identityCollectionLabels.contains($0.lowercased()) } ?? false
                previous = component
                return (labeled || looksLikeAnIdentifier(component)) ? ":id" : component
            }
            .joined(separator: "/")
        return path.isEmpty ? "\(scheme)://\(host)" : "\(scheme)://\(host)/\(path)"
    }

    /// Free text a subsystem logged: token-shaped runs go, the words around them stay.
    static func message(_ text: String) -> String {
        let characters = Array(text)
        var kept = ""
        var index = 0
        var previousRun: String?
        while index < characters.count {
            guard isRunCharacter(characters[index]) else {
                kept.append(characters[index])
                index += 1
                continue
            }

            var run = ""
            while index < characters.count {
                if isRunCharacter(characters[index]) {
                    run.append(characters[index])
                    index += 1
                } else if characters[index] == " ",
                          run.last?.isNumber == true,
                          index + 1 < characters.count,
                          characters[index + 1].isNumber
                {
                    // A single space between digit groups: one card or account number spaced out.
                    run.append(characters[index])
                    index += 1
                } else {
                    break
                }
            }
            if let equals = run.firstIndex(of: "="),
               credentialLabels.contains(run[..<equals].lowercased())
            {
                kept += "\(run[...equals]):id"
                previousRun = run
                continue
            }

            let labeled = previousRun.map { credentialLabels.contains($0.lowercased()) } ?? false
            kept += (labeled || carriesASecret(run)) ? ":id" : run
            previousRun = run
        }
        return kept
    }

    private static func isRunCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "@"
            || tokenPunctuation.contains(character)
    }

    /// A lone short number in a sentence is a count, not a card — only long ones go.
    private static func carriesASecret(_ run: String) -> Bool {
        if run.isEmpty {
            return false
        }
        if run.contains("@") {
            return true
        }
        if run.allSatisfy({ $0.isNumber || $0 == " " }) {
            let digits = run.filter(\.isNumber)
            if run.contains(" ") {
                // Spaced groups are a card, told from a row of years by the check digit.
                return (13...19).contains(digits.count) && passesLuhn(digits)
            }
            return digits.count >= 16
        }
        return looksLikeAnIdentifier(run)
    }

    private static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for character in digits.reversed() {
            guard var digit = character.wholeNumberValue else {
                return false
            }

            if double {
                digit *= 2
                if digit > 9 {
                    digit -= 9
                }
            }
            sum += digit
            double.toggle()
        }
        return sum % 10 == 0
    }

    private static func looksLikeAnIdentifier(_ segment: String) -> Bool {
        if segment.allSatisfy(\.isNumber) {
            return true
        }
        // An address in a path is the person, spelled out.
        if segment.contains("@") {
            return true
        }
        if segment.count >= 16,
           segment.allSatisfy({ $0.isHexDigit || $0 == "-" })
        {
            return true
        }
        // Long and digit-bearing over the token alphabet: base64url, a JWT, a
        // percent-escaped value. A phrase this long carries no digit, so it stays.
        if segment.count >= 16,
           segment.contains(where: \.isNumber),
           segment.allSatisfy({ $0.isLetter || $0.isNumber || tokenPunctuation.contains($0) })
        {
            return true
        }
        return false
    }
}
