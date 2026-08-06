import Foundation

/// What may leave the device from a URL. The query is dropped whole rather than
/// filtered — a token, an email and a search term all arrive as query items, and
/// an allow-list of names is a list somebody has to keep correct forever. Path
/// segments that look like identifiers are replaced for the same reason: an
/// account id in a path is the same disclosure as one in a query.
enum Redaction {
    static func url(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme, let host = url.host else {
            return ""
        }

        let path = url.pathComponents
            .filter { $0 != "/" }
            .map { looksLikeAnIdentifier($0) ? ":id" : $0 }
            .joined(separator: "/")
        return path.isEmpty ? "\(scheme)://\(host)" : "\(scheme)://\(host)/\(path)"
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
        // A reset token, an invite code, a signed blob: long, unbroken, and
        // carrying digits. A path word that long is hyphenated or spelled out —
        // `payment-methods` keeps its shape, `aB3xK9zQ7mW2pL5v` does not.
        if segment.count >= 16,
           segment.contains(where: \.isNumber),
           segment.allSatisfy({ $0.isLetter || $0.isNumber })
        {
            return true
        }
        return false
    }
}
