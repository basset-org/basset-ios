@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct NotificationSettingsTests {
    /// Authorized and invisible at once — checking only the status misses it.
    @Test func anAuthorizedAppWithBannersOffReportsTheSwitchRatherThanTheStatus() {
        var out = readings()
        NotificationSettings.write(
            NotificationSettingsReading(
                authorizationStatus: "authorized",
                switches: [
                    .init(name: "alert", state: "disabled"),
                    .init(name: "sound", state: "enabled"),
                    .init(name: "badge", state: "enabled"),
                ]
            ),
            into: &out
        )

        #expect(rendered(out.build(), .authorizationStatus) == "authorized")
        #expect(rendered(out.build(), .occurrenceCount) == "1")
        #expect(rendered(out.additionalEntities()[0], .notificationSetting) == "alert")
        #expect(rendered(out.additionalEntities()[0], .settingState) == "disabled")
    }

    /// Everything enabled needs no rows; the finding is always the switch turned off.
    @Test func everythingEnabledProducesNoSwitchRows() {
        var out = readings()
        NotificationSettings.write(
            NotificationSettingsReading(
                authorizationStatus: "authorized",
                switches: [.init(name: "alert", state: "enabled")]
            ),
            into: &out
        )

        #expect(rendered(out.build(), .occurrenceCount) == "0")
        #expect(out.additionalEntities().isEmpty)
    }

    /// A setting the device cannot offer is not a setting the user switched off.
    @Test func unsupportedIsKeptDistinctFromDisabled() {
        #expect(NotificationSettingsReading.nameOfSetting(0) == "notSupported")
        #expect(NotificationSettingsReading.nameOfSetting(1) == "disabled")
        #expect(NotificationSettingsReading.nameOfSetting(2) == "enabled")
        #expect(NotificationSettingsReading.nameOfSetting(6) == "unrecognised(6)")
    }

    /// Provisional delivers quietly with no banner — collapsing it into authorized hides it.
    @Test func provisionalAndEphemeralAreNotCollapsedIntoAuthorized() {
        #expect(NotificationSettingsReading.nameOfAuthorization(2) == "authorized")
        #expect(NotificationSettingsReading.nameOfAuthorization(3) == "provisional")
        #expect(NotificationSettingsReading.nameOfAuthorization(4) == "ephemeral")
    }

    @Test func hiddenPreviewsAreReportedBecauseTheyEmptyTheNotification() {
        #expect(NotificationSettingsReading.nameOfPreviews(0) == "always")
        #expect(NotificationSettingsReading.nameOfPreviews(1) == "whenAuthenticated")
        #expect(NotificationSettingsReading.nameOfPreviews(2) == "never")
    }

    @Test func alertStyleNamesTheThreeShapesANotificationCanTake() {
        #expect(NotificationSettingsReading.nameOfAlertStyle(0) == "none")
        #expect(NotificationSettingsReading.nameOfAlertStyle(1) == "banner")
        #expect(NotificationSettingsReading.nameOfAlertStyle(2) == "alert")
    }

    @Test func anAppThatDoesNotNotifyIsSaidRatherThanLeftSilent() {
        var out = readings()
        NotificationSettings.write(NotificationSettingsReading(), into: &out)

        #expect(out.build().componentIDs == [.mechanismStatus])
    }

    /// Read through the runtime — a non-settings object returns nil, not a raise.
    @Test func somethingThatIsNotASettingsObjectIsSurvived() {
        #expect(NotificationSettingsReading(NSObject()).authorizationStatus == nil)
        #expect(NotificationSettingsReading(nil).authorizationStatus == nil)
    }

    /// `alertSetting` reads as `alert`; the `Setting` suffix is dropped everywhere.
    @Test func theSettingSuffixIsDroppedFromEveryName() {
        #expect(NotificationSettings.switches.allSatisfy { $0.hasSuffix("Setting") })
        let reading = NotificationSettingsReading(
            authorizationStatus: "authorized",
            switches: [.init(name: "lockScreen", state: "disabled")]
        )
        #expect(reading.switches.first?.name.hasSuffix("Setting") == false)
    }

    private func readings() -> Readings {
        Readings(.notificationSetting)
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}

/// Stores the handler past the call frame — a stack-allocated block cannot survive it.
private class LateAnswerer: NSObject {
    var held: ((AnyObject?) -> Void)?
    var answered: String?

    @objc func answerLater(_ handler: @escaping (AnyObject?) -> Void) {
        held = handler
    }
}

@Suite(.serialized)
struct NotificationSettingsBlockTests {
    /// A block outliving its stack frame crashes the process, not the assertion.
    @Test func theBlockSurvivesTheFrameThatPassedIt() {
        let receiver = LateAnswerer()

        let asked = NotificationSettings.ask(
            receiver,
            #selector(LateAnswerer.answerLater)
        ) { value in
            receiver.answered = value as? String
        }

        #expect(asked)
        #expect(receiver.held != nil, "the callee was passed no handler at all")

        receiver.held?("answered" as NSString)
        #expect(receiver.answered == "answered")
    }

    @Test func aReceiverWithoutTheMethodIsSaidRatherThanCalled() {
        let asked = NotificationSettings.ask(
            NSObject(),
            Selector(("aMethodNothingImplements:"))
        ) { _ in
            Issue.record("a method that does not exist was called anyway")
        }

        #expect(asked == false)
    }
}

#if canImport(UIKit)
/// Not an app bundle, so this takes the guarded path rather than reaching a real centre.
@Suite(.serialized)
struct NotificationSettingsWiringTests {
    @Test func aProcessThatIsNotAnAppSaysSoRatherThanReachingForACentre() {
        let harness = InstrumentHarness<NotificationSettings>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading(timeout: 4)
        #expect(reading != nil)
        let said = reading?.components.contains {
            $0.id == .authorizationStatus || $0.id == .mechanismStatus
        }
        #expect(said == true)
    }
}
#endif
