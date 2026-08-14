import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Named `AccessibilityFlags` — UIKit's own `AccessibilitySettings` would collide.
final class AccessibilityFlags: Streamable, PlainInstrument {
    static let id: InstrumentID = .accessibilitySettings
    static let entity = Entity.ID.deviceSetting

    #if canImport(UIKit)
    /// `prefersCrossFadeTransitions`'s notification has no Swift name, so it's absent on purpose.
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

    /// Named for what the user turned on, not the API — reads without a UIKit lookup.
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
        // `emitIfChanged`, not `emit` — several notifications can fire for one user action.
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
            // Reported as a finding, not an empty reading — rules out this whole domain.
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
        // Whichever arrives, the whole set is re-read, not just what changed.
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

/// Text size the user chose, and whether it's one of the 5 accessibility sizes above normal.
final class DynamicType: Streamable, PlainInstrument {
    static let id: InstrumentID = .dynamicType
    static let entity = Entity.ID.deviceSetting

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
        guard let application = HostApplication.shared else {
            context.emitIfChanged { out in
                out.put(.mechanismStatus("unavailable: this process has no application object"))
            }
            return
        }

        let category = application.preferredContentSizeCategory
        context.emitIfChanged { out in
            // The raw value's `UICTContentSizeCategory` prefix means nothing outside UIKit.
            out.put(.textSizeCategory(Self.name(of: category)))
            out.put(.accessibilityTextSize(category.isAccessibilityCategory))
        }
    }

    /// Mapped from the constants — the raw value is a Core Text abbreviation, not the name.
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

/// Language, region, calendar — reported as codes; display names would localise.
final class LocaleSettings: Snapshotable, PlainInstrument {
    static let id: InstrumentID = .localeSettings
    static let entity = Entity.ID.deviceSetting

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

    /// Follows the language, not the region.
    private static func direction(of locale: Locale) -> String {
        // The locale's own language — Punjabi's script varies by region, not the code.
        guard locale.language.languageCode != nil else {
            return "unknown"
        }

        return switch locale.language.characterDirection {
        case .rightToLeft: "rightToLeft"
        case .leftToRight: "leftToRight"
        default: "unknown"
        }
    }

    /// Read from the locale's format, not a region lookup — a user override wins.
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
