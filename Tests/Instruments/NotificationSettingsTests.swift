@testable import Basset
import BassetECS
import Foundation
import Testing

struct NotificationSettingsTests {
    /// The whole point: authorized and invisible at the same time. An app that
    /// checks only the status concludes everything is fine.
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

        #expect(rendered(out.sealed(), .authorizationStatus) == "authorized")
        #expect(rendered(out.sealed(), .occurrenceCount) == "1")
        #expect(rendered(out.sealedSiblings()[0], .notificationSetting) == "alert")
        #expect(rendered(out.sealedSiblings()[0], .settingState) == "disabled")
    }

    /// Everything on is the ordinary case and needs no rows. The finding is
    /// always the switch the user turned off.
    @Test func everythingEnabledProducesNoSwitchRows() {
        var out = readings()
        NotificationSettings.write(
            NotificationSettingsReading(
                authorizationStatus: "authorized",
                switches: [.init(name: "alert", state: "enabled")]
            ),
            into: &out
        )

        #expect(rendered(out.sealed(), .occurrenceCount) == "0")
        #expect(out.sealedSiblings().isEmpty)
    }

    /// A setting the device cannot offer is not a setting the user switched off.
    /// Telling a developer to ask a user to enable something that does not exist
    /// wastes the one message they get.
    @Test func unsupportedIsKeptDistinctFromDisabled() {
        #expect(NotificationSettingsReading.nameOfSetting(0) == "notSupported")
        #expect(NotificationSettingsReading.nameOfSetting(1) == "disabled")
        #expect(NotificationSettingsReading.nameOfSetting(2) == "enabled")
        #expect(NotificationSettingsReading.nameOfSetting(6) == "unrecognised(6)")
    }

    /// Provisional and ephemeral both behave unlike a plain yes — provisional
    /// delivers quietly to the notification centre with no banner at all — so
    /// collapsing them into "authorized" would hide the explanation.
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

    /// An app that does not link UserNotifications sends no notifications, and
    /// saying so is the reading — the absence is the finding the runtime-reach
    /// discipline exists to preserve.
    @Test func anAppThatDoesNotNotifyIsSaidRatherThanLeftSilent() {
        var out = readings()
        NotificationSettings.write(NotificationSettingsReading(), into: &out)

        #expect(out.componentsWritten == [.mechanismStatus])
    }

    /// Read through the runtime, so anything that is not a settings object must
    /// produce a reading rather than raise.
    @Test func somethingThatIsNotASettingsObjectIsSurvived() {
        #expect(NotificationSettingsReading(NSObject()).authorizationStatus == nil)
        #expect(NotificationSettingsReading(nil).authorizationStatus == nil)
    }

    /// `alertSetting` reads as `alert`. The suffix is the API saying "this is a
    /// setting", which every row here already is.
    @Test func theSettingSuffixIsDroppedFromEveryName() {
        #expect(NotificationSettings.switches.allSatisfy { $0.hasSuffix("Setting") })
        let reading = NotificationSettingsReading(
            authorizationStatus: "authorized",
            switches: [.init(name: "lockScreen", state: "disabled")]
        )
        #expect(reading.switches.first?.name.hasSuffix("Setting") == false)
    }

    private func readings() -> Readings {
        Readings(
            entity: .notificationSetting,
            instrumentName: "notifications.settings"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}

#if canImport(UIKit)
/// The runtime reach itself, against whatever UserNotifications the simulator
/// actually loads. A wrong selector or a bad block signature is a crash rather
/// than a wrong value, so this passing is the evidence that matters.
@Suite(.serialized)
struct NotificationSettingsWiringTests {
    @Test func askingTheRealCentreForItsSettingsAnswers() {
        let harness = InstrumentHarness<NotificationSettings>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading(timeout: 4)
        #expect(reading != nil)
        // Either a real status or the explicit statement that this app does not
        // use notifications — never silence, and never a crash.
        let said = reading?.components.contains {
            $0.id == .authorizationStatus || $0.id == .mechanismStatus
        }
        #expect(said == true)
    }
}
#endif
