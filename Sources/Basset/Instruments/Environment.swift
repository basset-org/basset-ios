import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Every accessibility setting the app is supposed to adapt to, and the ones the
/// user changed while it was open.
///
/// The single-affected-user case in its purest form. Reduce Motion makes
/// `UIView.animate` run with a zero duration, so an app sequencing work off
/// animation completion handlers behaves differently for that user and identically
/// for everyone testing it. Bold Text and the accessibility text sizes change
/// intrinsic content size and break layouts that were fine on a developer's
/// device. Guided Access silently forbids things. None of it is visible to the app
/// from the inside, and all of it is free to read.
///
/// **Twenty settings, only the ones that are on.** Twenty rows of `false` on every
/// capture bury the one that is true, which is the whole finding.
///
/// Named `AccessibilityFlags` rather than `…Settings` because UIKit ships an
/// `AccessibilitySettings`. Inside this module the local type shadows it and
/// compiles; the collision surfaces only in a file importing both, which is every
/// test. Module-qualifying is no escape — the module is `Basset` and it contains a
/// type called `Basset`, so `Basset.AccessibilitySettings` resolves to the type.
final class AccessibilityFlags: StreamingInstrument {
    static let id: InstrumentWireID = .accessibilitySettings
    static let entity = Entity.WireID.deviceSetting

    #if canImport(UIKit)
    /// Nineteen of the twenty post a change notification Swift can name.
    /// `prefersCrossFadeTransitions` is the exception: its ObjC constant is
    /// declared outside the `UIAccessibility` class and the importer does not
    /// bring it into that namespace, so it is reachable only as a raw string —
    /// and a notification constant's value need not be its symbol's name, as
    /// `CoreDataNotifications` shows. Rather than subscribe to a string nothing
    /// here can verify, it rides the re-read any of the other nineteen triggers.
    /// It is reported either way; only a change to it alone is seen late.
    static var changeNotificationNames: [NSNotification.Name] {
        [
            UIAccessibility.voiceOverStatusDidChangeNotification,
            UIAccessibility.switchControlStatusDidChangeNotification,
            UIAccessibility.assistiveTouchStatusDidChangeNotification,
            UIAccessibility.guidedAccessStatusDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.boldTextStatusDidChangeNotification,
            UIAccessibility.buttonShapesEnabledStatusDidChangeNotification,
            UIAccessibility.invertColorsStatusDidChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.differentiateWithoutColorDidChangeNotification,
            UIAccessibility.grayscaleStatusDidChangeNotification,
            UIAccessibility.speakScreenStatusDidChangeNotification,
            UIAccessibility.speakSelectionStatusDidChangeNotification,
            UIAccessibility.monoAudioStatusDidChangeNotification,
            UIAccessibility.closedCaptioningStatusDidChangeNotification,
            UIAccessibility.videoAutoplayStatusDidChangeNotification,
            UIAccessibility.onOffSwitchLabelsDidChangeNotification,
            UIAccessibility.shakeToUndoDidChangeNotification,
        ]
    }

    /// Named for what the user turned on rather than for the API that reports it:
    /// a reader who has never written UIKit still knows what "reduce motion"
    /// means, where `isReduceMotionEnabled` is a symbol to go and look up.
    static var current: [(name: String, isOn: Bool)] {
        [
            ("voiceOver", UIAccessibility.isVoiceOverRunning),
            ("switchControl", UIAccessibility.isSwitchControlRunning),
            ("assistiveTouch", UIAccessibility.isAssistiveTouchRunning),
            ("guidedAccess", UIAccessibility.isGuidedAccessEnabled),
            ("reduceMotion", UIAccessibility.isReduceMotionEnabled),
            ("prefersCrossFadeTransitions", UIAccessibility.prefersCrossFadeTransitions),
            ("reduceTransparency", UIAccessibility.isReduceTransparencyEnabled),
            ("boldText", UIAccessibility.isBoldTextEnabled),
            ("buttonShapes", UIAccessibility.buttonShapesEnabled),
            ("invertColours", UIAccessibility.isInvertColorsEnabled),
            ("darkerSystemColours", UIAccessibility.isDarkerSystemColorsEnabled),
            (
                "differentiateWithoutColour",
                UIAccessibility.shouldDifferentiateWithoutColor
            ),
            ("grayscale", UIAccessibility.isGrayscaleEnabled),
            ("speakScreen", UIAccessibility.isSpeakScreenEnabled),
            ("speakSelection", UIAccessibility.isSpeakSelectionEnabled),
            ("monoAudio", UIAccessibility.isMonoAudioEnabled),
            ("closedCaptioning", UIAccessibility.isClosedCaptioningEnabled),
            ("videoAutoplay", UIAccessibility.isVideoAutoplayEnabled),
            ("onOffSwitchLabels", UIAccessibility.isOnOffSwitchLabelsEnabled),
            ("shakeToUndo", UIAccessibility.isShakeToUndoEnabled),
        ]
    }

    private func report(into context: Context) {
        // `emitIfChanged` rather than `emit`: several of these notifications
        // describe one user action, so a single toggle can arrive twice.
        context.emitIfChanged { out in
            Self.write(Self.current, into: &out)
        }
    }
    #endif

    private var observers: [NSObjectProtocol] = []

    init() {}

    static func write(_ settings: [(name: String, isOn: Bool)],
                      into out: inout Readings)
    {
        let enabled = settings.filter(\.isOn)
        out.put(.occurrenceCount(UInt64(enabled.count)))

        guard let first = enabled.first else {
            // Everything at its default is a finding rather than an empty
            // reading: it rules out this whole domain as the cause.
            out.put(.mechanismStatus("every accessibility setting is at its default"))
            return
        }

        out.put(.settingName(first.name))
        out.put(.settingEnabled(true))
        for setting in enabled.dropFirst() {
            out.also(Self.entity) { sibling in
                sibling.put(.settingName(setting.name))
                sibling.put(.settingEnabled(true))
            }
        }
    }

    func observe(_ context: Context) {
        #if canImport(UIKit)
        report(into: context)
        // Not every setting posts a change notification, and the ones that do post
        // their own rather than a shared one. Whichever arrives, the whole set is
        // re-read — reporting only what changed makes the reader remember the rest.
        for name in Self.changeNotificationNames {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.report(into: context)
                }
            )
        }
        #endif
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}

/// The text size the user chose, and whether it is one of the accessibility
/// sizes.
///
/// Separate from `environment.accessibility` because it is not a flag and not
/// only an accessibility setting: every user has a text size, most have moved it
/// at some point, and the five accessibility sizes above the normal range are
/// where layouts stop fitting. A screen that is correct at `large` and clipped at
/// `accessibilityExtraExtraExtraLarge` is not a bug anybody sees on a development
/// device, because nobody develops at AX5.
///
/// `isAccessibilityCategory` is carried alongside the name rather than left for
/// the reader to derive: the boundary is where behaviour changes, and knowing the
/// category name means nothing without knowing which side of it the user is on.
final class DynamicType: StreamingInstrument {
    static let id: InstrumentWireID = .dynamicType
    static let entity = Entity.WireID.deviceSetting

    private var observer: NSObjectProtocol?

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        report(into: context)
        observer = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.report(into: context)
        }
        #endif
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    #if canImport(UIKit)
    private func report(into context: Context) {
        let category = UIApplication.shared.preferredContentSizeCategory
        context.emitIfChanged { out in
            // The raw value carries a `UICTContentSizeCategory` prefix nobody
            // outside UIKit reads. The suffix is the size the user picked.
            out.put(.textSizeCategory(Self.name(of: category)))
            out.put(.accessibilityTextSize(category.isAccessibilityCategory))
        }
    }

    /// Mapped from the constants rather than derived from the raw value. UIKit's
    /// values are Core Text abbreviations — `.large` is `UICTContentSizeCategoryL`
    /// and `.accessibilityExtraExtraExtraLarge` is `…AccessibilityXXXL` — so
    /// stripping the prefix yields `L` and `accessibilityXXXL`, which is what a
    /// reader would then be shown as the user's text size. A constant's value is
    /// not its symbol's name.
    static func name(of category: UIContentSizeCategory) -> String {
        switch category {
        case .extraSmall: "extraSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .extraLarge: "extraLarge"
        case .extraExtraLarge: "extraExtraLarge"
        case .extraExtraExtraLarge: "extraExtraExtraLarge"
        case .accessibilityMedium: "accessibilityMedium"
        case .accessibilityLarge: "accessibilityLarge"
        case .accessibilityExtraLarge: "accessibilityExtraLarge"
        case .accessibilityExtraExtraLarge: "accessibilityExtraExtraLarge"
        case .accessibilityExtraExtraExtraLarge: "accessibilityExtraExtraExtraLarge"
        case .unspecified: "unspecified"
        default: "unrecognised(\(category.rawValue))"
        }
    }

    #endif
}

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
        // The locale's own language, not one rebuilt from its code. Punjabi is
        // written in Gurmukhi in India and in the Arabic script in Pakistan, and
        // `pa-Arab` reads as left-to-right once the script is thrown away —
        // which is the reading that decides whether a layout was ever exercised
        // in the direction it broke in.
        guard locale.language.languageCode != nil else {
            return "unknown"
        }

        return switch locale.language.characterDirection {
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
