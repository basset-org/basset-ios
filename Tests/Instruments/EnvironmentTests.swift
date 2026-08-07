@testable import Basset
import BassetECS
import Foundation
import Testing

struct AccessibilityFlagsTests {
    /// Twenty rows of `false` would bury the one that is true, and which setting
    /// the user turned on is the entire finding.
    @Test func onlyTheSettingsThatAreOnAreEmitted() {
        var out = readings()
        AccessibilityFlags.write(
            [
                ("voiceOver", false),
                ("reduceMotion", true),
                ("boldText", false),
                ("grayscale", true),
            ],
            into: &out
        )

        #expect(rendered(out.sealed(), .settingName) == "reduceMotion")
        #expect(out.sealedSiblings().count == 1)
        #expect(rendered(out.sealedSiblings()[0], .settingName) == "grayscale")
    }

    /// Nothing turned on rules this whole domain out as the cause, which is a
    /// finding. An empty reading would look like the instrument failing.
    @Test func everythingAtItsDefaultIsSaidRatherThanLeftSilent() {
        var out = readings()
        AccessibilityFlags.write(
            [("voiceOver", false), ("boldText", false)],
            into: &out
        )

        #expect(rendered(out.sealed(), .occurrenceCount) == "0")
        #expect(out.componentsWritten.contains(.mechanismStatus))
        #expect(out.sealedSiblings().isEmpty)
    }

    @Test func theCountIsOfWhatIsOnRatherThanOfWhatWasChecked() {
        var out = readings()
        AccessibilityFlags.write(
            [("a", true), ("b", false), ("c", true), ("d", true)],
            into: &out
        )

        #expect(rendered(out.sealed(), .occurrenceCount) == "3")
    }

    private func readings() -> Readings {
        Readings(
            entity: .deviceSetting,
            instrumentName: "environment.accessibility"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}

struct LocaleSettingsTests {
    /// Codes, never display names: a display name is localised into the device's
    /// own language, so a capture from a Japanese device would describe itself in
    /// Japanese and two captures of one locale would not match.
    @Test func aLocaleIsReportedAsCodesRatherThanNames() {
        var out = readings()
        LocaleSettings.write(Locale(identifier: "ja_JP"), into: &out)

        #expect(rendered(out.sealed(), .languageCode) == "ja")
        #expect(rendered(out.sealed(), .regionCode) == "JP")
    }

    /// The setting most likely to break a layout nobody tested against, and it
    /// follows the language rather than the region.
    @Test func rightToLeftIsDetectedFromTheLanguage() {
        var arabic = readings()
        LocaleSettings.write(Locale(identifier: "ar_EG"), into: &arabic)

        var english = readings()
        LocaleSettings.write(Locale(identifier: "en_US"), into: &english)

        #expect(rendered(arabic.sealed(), .layoutDirection) == "rightToLeft")
        #expect(rendered(english.sealed(), .layoutDirection) == "leftToRight")
    }

    /// Punjabi is written in Gurmukhi in India and in the Arabic script in
    /// Pakistan, and Foundation answers `rightToLeft` for `pa-Arab` only when it
    /// is asked about the locale's own language. Asked about a language rebuilt
    /// from the code alone it answers `leftToRight` for both, which is what this
    /// guards. `ar`/`en` cannot: they read the same either way.
    @Test func rightToLeftFollowsTheScriptRatherThanTheLanguageCode() {
        var arabicScript = readings()
        LocaleSettings.write(Locale(identifier: "pa_Arab_PK"), into: &arabicScript)

        var gurmukhiScript = readings()
        LocaleSettings.write(Locale(identifier: "pa_Guru_IN"), into: &gurmukhiScript)

        #expect(rendered(arabicScript.sealed(), .layoutDirection) == "rightToLeft")
        #expect(rendered(gurmukhiScript.sealed(), .layoutDirection) == "leftToRight")
    }

    @Test func aNonGregorianCalendarIsReportedAsItself() {
        var out = readings()
        LocaleSettings.write(Locale(identifier: "fa_IR@calendar=persian"), into: &out)

        #expect(rendered(out.sealed(), .calendarIdentifier) == "persian")
    }

    @Test func theMeasurementSystemFollowsTheRegion() {
        var french = readings()
        LocaleSettings.write(Locale(identifier: "fr_FR"), into: &french)

        var american = readings()
        LocaleSettings.write(Locale(identifier: "en_US"), into: &american)

        #expect(rendered(french.sealed(), .usesMetricSystem) == "true")
        #expect(rendered(american.sealed(), .usesMetricSystem) == "false")
    }

    /// Read from the locale's own time format rather than a region lookup,
    /// because the user can override it and the override is what the app is
    /// handed.
    @Test func theTimeFormatIsReadFromTheLocaleRatherThanAssumedFromTheRegion() {
        var british = readings()
        LocaleSettings.write(Locale(identifier: "en_GB"), into: &british)

        var american = readings()
        LocaleSettings.write(Locale(identifier: "en_US"), into: &american)

        #expect(rendered(british.sealed(), .uses24HourTime) == "true")
        #expect(rendered(american.sealed(), .uses24HourTime) == "false")
    }

    private func readings() -> Readings {
        Readings(
            entity: .deviceSetting,
            instrumentName: "environment.locale"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
