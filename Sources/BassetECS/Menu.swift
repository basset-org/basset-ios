import Foundation

/// What a caller reads to choose an instrument. Every field derives from `InstrumentID`.
public struct MenuEntry: Codable, Sendable, Equatable {
    public let id: UInt16
    public let instrument: String
    public let domain: Domain
    public let delivery: Delivery
    public let minIOS: Int
    public let simulator: Bool
    public let metadata: InstrumentMetadata

    public init(
        id: UInt16,
        instrument: String,
        domain: Domain,
        delivery: Delivery,
        minIOS: Int,
        simulator: Bool,
        metadata: InstrumentMetadata
    ) {
        self.id = id
        self.instrument = instrument
        self.domain = domain
        self.delivery = delivery
        self.minIOS = minIOS
        self.simulator = simulator
        self.metadata = metadata
    }
}

public struct Menu: Codable, Sendable, Equatable {
    public let instruments: [MenuEntry]

    public init(instruments: [MenuEntry]) {
        self.instruments = instruments
    }
}

/// The readable projection — excluded from the device target, which carries no display metadata.
public extension Menu {
    func markdown() -> String {
        let domains = Dictionary(grouping: instruments, by: \.domain.rawValue)
            .sorted { $0.key < $1.key }

        var out = ["# basset instruments", ""]
        out.append(
            "\(instruments.count) instruments across \(domains.count) "
                + "\(domains.count == 1 ? "domain" : "domains"). "
                + "Name one in a request: `basset request create -i <instrument>`."
        )

        for (domain, entries) in domains {
            out.append("")
            out.append("## \(domain)")
            for entry in entries.sorted(by: { $0.instrument < $1.instrument }) {
                out.append("")
                out.append(entry.markdown())
            }
        }

        return out.joined(separator: "\n") + "\n"
    }
}

extension MenuEntry {
    public func markdown() -> String {
        var out = ["### `\(instrument)`"]

        out.append("")
        out.append(metadata.summary)
        out.append("")
        out.append("**Activate when** \(metadata.whenToUse.startingLowercase)")
        if !metadata.reveals.isEmpty {
            out.append("")
            out.append("**Reveals**")
            out.append(contentsOf: metadata.reveals.map { "- \($0)" })
        }

        out.append("")
        out.append("| | |")
        out.append("|---|---|")
        out
            .append(
                "| Delivery | \(delivery.rawValue), \(metadata.cadence.rawValue) |"
            )
        out.append("| Describes | \(describes) |")
        out.append("| Mechanism | \(metadata.mechanism.rawValue) |")
        out.append("| Overhead | \(metadata.overhead.rawValue) |")
        out.append("| Requires | \(requirements) |")
        if !metadata.related.isEmpty {
            out.append("| Related | \(Self.code(metadata.related)) |")
        }

        if !metadata.config.isEmpty {
            out.append("")
            out.append("**Config** (`\(instrument):key=value,...`)")
            out.append(contentsOf: metadata.config.map {
                "- `\($0.key)` (\($0.type.rendered)): \($0.description)"
            })
        }

        return out.joined(separator: "\n")
    }

    /// Stated for every instrument, not just the retrospective ones, so it reads as a field.
    private var describes: String {
        guard metadata.observed == .pastRuns else {
            return "this run"
        }

        return "runs that already ended"
    }

    private var requirements: String {
        var notes = ["iOS \(minIOS)+"]
        if !simulator {
            notes.append("hardware only, no simulator")
        }
        notes.append("basset \(metadata.minimumSDKVersion)+")
        return notes.joined(separator: ", ")
    }

    private static func code(_ items: [String]) -> String {
        items.map { "`\($0)`" }.joined(separator: ", ")
    }
}

private extension String {
    var startingLowercase: String {
        guard let first else {
            return self
        }

        return first.lowercased() + dropFirst()
    }
}

/// Derived rather than generated: every field is a fact the id space already holds.
public extension Menu {
    static var current: Menu {
        Menu(instruments: InstrumentID.allCases
            // basset reports on itself — never requestable, so never listed here.
            .filter { $0.domain != .basset }
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.menuEntry))
    }
}

public extension InstrumentID {
    var menuEntry: MenuEntry {
        MenuEntry(
            id: rawValue,
            instrument: name,
            domain: domain,
            delivery: delivery,
            minIOS: availability.minIOS,
            simulator: availability.simulator,
            metadata: metadata
        )
    }
}
