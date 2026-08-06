import BassetECS
import Foundation

/// The App Transport Security posture this build shipped with.
///
/// ATS is decided at build time and enforced at run time, and when it refuses a
/// load the app gets a generic `URLError` that looks like any other failure. The
/// developer's own machine usually cannot reproduce it: a debug build talking to
/// a local server over http is exempt, and the shipped one is not. So a URL that
/// works everywhere except in production has an answer that lives in the
/// `Info.plist` and nowhere else.
///
/// Free, like `permissions.status`'s usage descriptions and for the same reason:
/// the build already carries it, and reading it prompts nothing and costs
/// nothing.
final class TransportSecurity: SnapshotInstrument {
    /// The blanket exemptions, each of which widens what the whole app may load.
    /// Named rather than reported as raw keys, because the key is what a reader
    /// would have to look up and the name is what they wanted.
    private enum Relaxation: String, CaseIterable {
        case webContent = "NSAllowsArbitraryLoadsInWebContent"
        case media = "NSAllowsArbitraryLoadsForMedia"
        case localNetworking = "NSAllowsLocalNetworking"

        var description: String {
            switch self {
            case .webContent: "arbitrary loads allowed in web content"
            case .media: "arbitrary loads allowed for media"
            case .localNetworking: "local networking allowed"
            }
        }
    }

    static let id: InstrumentWireID = .transportSecurity
    static let entity = Entity.WireID.transportSecurity

    private static let key = "NSAppTransportSecurity"

    init() {}

    static func write(_ settings: [String: Any]?, into out: inout Readings) {
        guard let settings else {
            // No dictionary is ATS at its defaults, which is a posture rather
            // than an absence: every load must be https with TLS 1.2 or better.
            out.put(.arbitraryLoadsAllowed(false))
            out.put(.mechanismStatus("no NSAppTransportSecurity key; defaults apply"))
            return
        }

        out
            .put(.arbitraryLoadsAllowed(settings["NSAllowsArbitraryLoads"] as? Bool ??
                    false))
        for relaxation in Relaxation.allCases
            where settings[relaxation.rawValue] as? Bool == true
        {
            out.put(.detail(relaxation.description))
        }

        let domains = settings["NSExceptionDomains"] as? [String: Any] ?? [:]
        out.put(.occurrenceCount(UInt64(domains.count)))

        // Sorted, so two captures of one build list the exceptions in one order.
        for name in domains.keys.sorted() {
            let exception = domains[name] as? [String: Any] ?? [:]
            out.also(Self.entity) { sibling in
                sibling.put(.exceptionDomain(name))
                sibling.put(
                    .insecureLoadsAllowed(
                        exception["NSExceptionAllowsInsecureHTTPLoads"] as? Bool ?? false
                    )
                )
                if let minimum = exception["NSExceptionMinimumTLSVersion"] as? String {
                    sibling.put(.minimumTLSVersion(minimum))
                }
            }
        }
    }

    func reading(_ out: inout Readings) {
        Self.write(
            Bundle.main.object(forInfoDictionaryKey: Self.key) as? [String: Any],
            into: &out
        )
    }
}
