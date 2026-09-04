import BassetEntityComponent
import Foundation
import Testing

struct ComponentHealthRangeTests {
    @Test func theLowestBandAppliesBelowItsUpperBound() {
        let range = InstrumentMetadata.ComponentHealthRange(
            component: .cpuUsageRatio,
            displayUnit: "%",
            displayScale: 0.01,
            bands: [
                InstrumentMetadata.HealthBand(upTo: 0.5, health: .ok),
                InstrumentMetadata.HealthBand(upTo: 0.8, health: .warning),
                InstrumentMetadata.HealthBand(upTo: nil, health: .fault),
            ]
        )

        #expect(range.health(for: 0) == .ok)
        #expect(range.health(for: 0.49) == .ok)
        #expect(range.health(for: 0.5) == .warning)
        #expect(range.health(for: 0.79) == .warning)
        #expect(range.health(for: 0.8) == .fault)
        #expect(range.health(for: 1000) == .fault)
    }

    /// Direction-agnostic on purpose: fps counts down into fault, cpu counts up into it.
    @Test func aDescendingRangeReadsJustAsWell() {
        let range = InstrumentMetadata.ComponentHealthRange(
            component: .fps,
            displayUnit: "fps",
            displayScale: 1,
            bands: [
                InstrumentMetadata.HealthBand(upTo: 30, health: .fault),
                InstrumentMetadata.HealthBand(upTo: 50, health: .warning),
                InstrumentMetadata.HealthBand(upTo: nil, health: .ok),
            ]
        )

        #expect(range.health(for: 0) == .fault)
        #expect(range.health(for: 29) == .fault)
        #expect(range.health(for: 30) == .warning)
        #expect(range.health(for: 49) == .warning)
        #expect(range.health(for: 60) == .ok)
    }

    /// A mis-ordered range would quietly always answer its first band and never move.
    @Test func everyDeclaredRangeIsStrictlyAscendingAndExhaustive() {
        for id in InstrumentID.allCases {
            for range in id.metadata.ranges {
                #expect(
                    range.bands.last?.upTo == nil,
                    "\(id.name)/\(range.component): last band must have no upper bound"
                )

                let bounded = range.bands.dropLast().compactMap(\.upTo)
                #expect(
                    bounded.count == range.bands.count - 1,
                    "\(id.name)/\(range.component): only the last band may omit an upper bound"
                )
                for (lower, upper) in zip(bounded, bounded.dropFirst()) {
                    #expect(
                        lower < upper,
                        "\(id.name)/\(range.component): bands must be strictly ascending"
                    )
                }
            }
        }
    }

    @Test func everyDeclaredRangeScalesByAPositiveDivisor() {
        for id in InstrumentID.allCases {
            for range in id.metadata.ranges {
                #expect(
                    range.displayScale > 0,
                    "\(id.name)/\(range.component): displayScale must be positive"
                )
            }
        }
    }

    @Test func everyNanosecondRangeDisplaysAsMilliseconds() {
        for id in InstrumentID.allCases {
            for range in id.metadata.ranges
                where String(describing: range.component).hasSuffix("Nanoseconds")
            {
                #expect(
                    range.displayUnit == "ms",
                    "\(id.name)/\(range.component): nanosecond components display as ms"
                )
                #expect(
                    range.displayScale == 1000000,
                    "\(id.name)/\(range.component): nanosecond components scale by 1e6"
                )
            }
        }
    }
}

struct MetadataRangeDecodingTests {
    @Test func aRangeNamingAnUnknownComponentIsSkippedAndTheRestSurvives() throws {
        let json = """
        {
          "summary": "s",
          "whenToUse": "w",
          "reveals": [],
          "related": [],
          "mechanism": "\(InstrumentMetadata.Mechanism.statusRead.rawValue)",
          "cadence": "\(InstrumentMetadata.Cadence.once.rawValue)",
          "observed": "\(InstrumentMetadata.Observed.thisRun.rawValue)",
          "overhead": "\(InstrumentMetadata.Overhead.low.rawValue)",
          "ranges": [
            { "component": 65535, "displayUnit": "x", "displayScale": 1, "bands": [] },
            { "component": \(Component.ID.cpuUsageRatio.rawValue),
              "displayUnit": "%", "displayScale": 0.01, "bands": [] }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(
            InstrumentMetadata.self,
            from: Data(json.utf8)
        )

        #expect(decoded.ranges.count == 1)
        #expect(decoded.ranges.first?.component == .cpuUsageRatio)
    }
}
