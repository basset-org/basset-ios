@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct AccessibilityFlagsTests {
    /// Twenty rows of `false` would bury the one `true` — that's the entire finding.
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

        #expect(rendered(out.build(), .settingName) == "reduceMotion")
        #expect(out.additionalEntities().count == 1)
        #expect(rendered(out.additionalEntities()[0], .settingName) == "grayscale")
    }

    /// Nothing turned on is itself a finding — an empty reading looks like a failed instrument.
    @Test func everythingAtItsDefaultIsSaidRatherThanLeftSilent() {
        var out = readings()
        AccessibilityFlags.write(
            [("voiceOver", false), ("boldText", false)],
            into: &out
        )

        #expect(rendered(out.build(), .occurrenceCount) == "0")
        #expect(out.build().componentIDs.contains(.mechanismStatus))
        #expect(out.additionalEntities().isEmpty)
    }

    @Test func theCountIsOfWhatIsOnRatherThanOfWhatWasChecked() {
        var out = readings()
        AccessibilityFlags.write(
            [("a", true), ("b", false), ("c", true), ("d", true)],
            into: &out
        )

        #expect(rendered(out.build(), .occurrenceCount) == "3")
    }

    private func readings() -> Readings {
        Readings(.deviceSetting)
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.known == id }?.value.rendered
    }
}

struct LocaleSettingsTests {
    /// Codes, never display names — a display name localizes into the device's own language.
    @Test func aLocaleIsReportedAsCodesRatherThanNames() {
        var out = readings()
        LocaleSettings.write(Locale(identifier: "ja_JP"), into: &out)

        #expect(rendered(out.build(), .languageCode) == "ja")
        #expect(rendered(out.build(), .regionCode) == "JP")
    }

    /// Follows the language, not the region — likeliest setting to break an untested layout.
    @Test func rightToLeftIsDetectedFromTheLanguage() {
        var arabic = readings()
        LocaleSettings.write(Locale(identifier: "ar_EG"), into: &arabic)

        var english = readings()
        LocaleSettings.write(Locale(identifier: "en_US"), into: &english)

        #expect(rendered(arabic.build(), .layoutDirection) == "rightToLeft")
        #expect(rendered(english.build(), .layoutDirection) == "leftToRight")
    }

    /// Punjabi's script decides direction — code alone reads `leftToRight` either way.
    @Test func rightToLeftFollowsTheScriptRatherThanTheLanguageCode() {
        var arabicScript = readings()
        LocaleSettings.write(Locale(identifier: "pa_Arab_PK"), into: &arabicScript)

        var gurmukhiScript = readings()
        LocaleSettings.write(Locale(identifier: "pa_Guru_IN"), into: &gurmukhiScript)

        #expect(rendered(arabicScript.build(), .layoutDirection) == "rightToLeft")
        #expect(rendered(gurmukhiScript.build(), .layoutDirection) == "leftToRight")
    }

    @Test func aNonGregorianCalendarIsReportedAsItself() {
        var out = readings()
        LocaleSettings.write(Locale(identifier: "fa_IR@calendar=persian"), into: &out)

        #expect(rendered(out.build(), .calendarIdentifier) == "persian")
    }

    @Test func theMeasurementSystemFollowsTheRegion() {
        var french = readings()
        LocaleSettings.write(Locale(identifier: "fr_FR"), into: &french)

        var american = readings()
        LocaleSettings.write(Locale(identifier: "en_US"), into: &american)

        #expect(rendered(french.build(), .usesMetricSystem) == "true")
        #expect(rendered(american.build(), .usesMetricSystem) == "false")
    }

    /// Reads the locale's time format, not region — the user's override is what the app sees.
    @Test func theTimeFormatIsReadFromTheLocaleRatherThanAssumedFromTheRegion() {
        var british = readings()
        LocaleSettings.write(Locale(identifier: "en_GB"), into: &british)

        var american = readings()
        LocaleSettings.write(Locale(identifier: "en_US"), into: &american)

        #expect(rendered(british.build(), .uses24HourTime) == "true")
        #expect(rendered(american.build(), .uses24HourTime) == "false")
    }

    private func readings() -> Readings {
        Readings(.deviceSetting)
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.known == id }?.value.rendered
    }
}
