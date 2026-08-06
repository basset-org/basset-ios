import BassetECS
import Foundation

/// The language, region and calendar the app is actually running under.
///
/// The bug class this exists for is the one that reproduces nowhere: a crash only
/// users in one region see, a screen that lays out backwards, a date that parses
/// on every machine in the office and fails on a device set to a non-Gregorian
/// calendar. All of it is decided by settings the app never asked about and
/// usually never reads.
///
/// Reported as codes rather than display names. A display name is localised into
/// *the device's own* language, so a capture from a Japanese device would arrive
/// describing itself in Japanese and two captures of the same locale would not
/// match.
final class LocaleSettings: SnapshotInstrument {
    static let id: InstrumentWireID = .localeSettings
    static let entity = Entity.WireID.deviceSetting

    init() {}

    static func write(_ locale: Locale, into out: inout Readings) {
        out.put(.languageCode(locale.language.languageCode?.identifier ?? "unknown"))
        out.put(.calendarIdentifier("\(locale.calendar.identifier)"))
        out.put(.layoutDirection(direction(of: locale)))

        if let region = locale.region?.identifier {
            out.put(.regionCode(region))
        }
        out.put(.usesMetricSystem(locale.measurementSystem == .metric))
        out.put(.uses24HourTime(prefers24Hour(in: locale)))
    }

    /// Right-to-left is the setting most likely to break a layout that was never
    /// tested against it, and it follows the language rather than the region.
    private static func direction(of locale: Locale) -> String {
        guard let language = locale.language.languageCode else {
            return "unknown"
        }

        return switch Locale.Language(identifier: language.identifier)
            .characterDirection
        {
        case .rightToLeft: "rightToLeft"
        case .leftToRight: "leftToRight"
        default: "unknown"
        }
    }

    /// Read from the locale's own format rather than a region lookup: a user can
    /// set 24-hour time on a device in a region that does not default to it, and
    /// the override is what the app will actually be handed.
    private static func prefers24Hour(in locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(
            fromTemplate: "j",
            options: 0,
            locale: locale
        )
        guard let format else {
            return false
        }

        return !format.contains("a")
    }

    func reading(_ out: inout Readings) {
        Self.write(Locale.current, into: &out)
    }
}
