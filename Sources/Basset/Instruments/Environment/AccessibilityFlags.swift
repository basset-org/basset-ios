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
