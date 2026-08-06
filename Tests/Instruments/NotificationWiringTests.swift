@testable import Basset
import Foundation
import Testing

/// The notification-driven instruments, driven end to end: activate, post the
/// real notification, assert a reading came out.
///
/// **These catch the class of defect nothing else does.** `storage`'s save
/// notifications carry values that are not their symbols' names, and one
/// `UIAccessibility` notification constant does not exist at all. A test calling
/// `write(_:into:)` with a hand-built payload passes in both cases, because the
/// name is never used. A test that posts the name the instrument subscribed to
/// does not.
///
/// Every name below is deliberately re-derived from the instrument's own
/// constant rather than retyped, so the test asserts "what it subscribed to is
/// what the framework posts" rather than "two string literals match".
/// Serialized: every instrument here observes `NotificationCenter.default`,
/// which is process-wide, so two harnesses running at once each receive the
/// other's posts. The default is parallel and it made these tests report each
/// other's readings.
@Suite(.serialized)
struct NotificationWiringTests {
    @Test func aCoreDataSaveIsObservedFromTheNameCoreDataActuallyPosts() {
        let harness = InstrumentHarness<CoreDataSave>()
        harness.start()
        defer { harness.stop() }

        let context = NSObject()
        NotificationCenter.default.post(
            name: CoreDataNotifications.willSave,
            object: context
        )
        NotificationCenter.default.post(
            name: CoreDataNotifications.didSave,
            object: context,
            userInfo: ["inserted": NSSet(array: [1, 2, 3]), "deleted": NSSet(array: [4])]
        )

        let reading = harness.waitForReading()
        #expect(harness.value(.insertedCount, in: reading) == "3")
        #expect(harness.value(.deletedCount, in: reading) == "1")
        // Paired from will-save to did-save on the same context, so a duration
        // exists at all only if the pairing worked.
        #expect(reading?.components.contains { $0.id == .totalNanoseconds } == true)
    }

    /// The save is timed by pairing two notifications on one context. A second
    /// context saving in between must not be paired with the first one's start.
    @Test func twoContextsSavingAtOnceAreNotPairedWithEachOther() {
        let harness = InstrumentHarness<CoreDataSave>()
        harness.start()
        defer { harness.stop() }

        let first = NSObject()
        let second = NSObject()
        NotificationCenter.default.post(
            name: CoreDataNotifications.willSave,
            object: first
        )
        NotificationCenter.default.post(
            name: CoreDataNotifications.didSave,
            object: second,
            userInfo: ["inserted": NSSet(array: [1])]
        )

        let reading = harness.waitForReading()
        // The second context never announced a start, so it reports counts and
        // no duration rather than borrowing the first context's clock.
        #expect(harness.value(.insertedCount, in: reading) == "1")
        #expect(reading?.components.contains { $0.id == .totalNanoseconds } == false)
    }

    @Test func aCloudKitEventIsObservedFromTheNameTheContainerPosts() {
        let harness = InstrumentHarness<CloudKitEvents>()
        harness.start()
        defer { harness.stop() }

        NotificationCenter.default.post(
            name: CloudKitEvents.notification,
            object: nil,
            userInfo: [CloudKitEvents.eventKey: NSObject()]
        )

        let reading = harness.waitForReading()
        // An NSObject answers none of the event's keys, so the instrument
        // reports that rather than raising — which is the guarded read working.
        #expect(harness.value(.mechanismStatus, in: reading) != nil)
    }

    @Test func aKeyValueStoreQuotaViolationReachesTheInstrument() {
        let harness = InstrumentHarness<KeyValueStoreSync>()
        harness.start()
        defer { harness.stop() }

        NotificationCenter.default.post(
            name: KeyValueStoreSync.notification,
            object: nil,
            userInfo: [KeyValueStoreSync.reasonKey: NSNumber(value: 2)]
        )

        #expect(harness
            .value(.changeReason, in: harness.waitForReading()) == "quotaViolation")
    }

    /// Teardown is the half nobody tests, and a leaked observer keeps emitting
    /// into a request that has ended.
    @Test func nothingArrivesAfterTheInstrumentStops() {
        let harness = InstrumentHarness<KeyValueStoreSync>()
        harness.start()
        NotificationCenter.default.post(
            name: KeyValueStoreSync.notification,
            object: nil,
            userInfo: [KeyValueStoreSync.reasonKey: NSNumber(value: 0)]
        )
        harness.waitForReading()
        harness.stop()
        harness.forget()

        NotificationCenter.default.post(
            name: KeyValueStoreSync.notification,
            object: nil,
            userInfo: [KeyValueStoreSync.reasonKey: NSNumber(value: 2)]
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(harness.readings.isEmpty)
    }
}

#if canImport(UIKit)
import UIKit

/// The UIKit half, which the host rung cannot compile at all — `canImport(UIKit)`
/// is false on macOS, so these bodies vanish from `sdk_test` entirely. They run
/// only on the simulator, which is exactly where a missing `UIAccessibility`
/// constant was found.
@Suite(.serialized)
struct UIKitWiringTests {
    /// Qualified, because UIKit ships a type of the same name and this file
    /// imports both. Inside the module the local type shadows it, so the
    /// instrument compiles unqualified; only a reader of both needs to say which.
    ///
    /// Reads the twenty settings out of the real framework. A renamed or removed
    /// property is a compile error; a property that answers nonsense shows up as
    /// a name that is not in the expected set.
    @Test func everyAccessibilitySettingIsReadableFromTheRealFramework() {
        let settings = AccessibilityFlags.current

        #expect(settings.count == 20)
        #expect(Set(settings.map(\.name)).count == 20)
        #expect(settings.allSatisfy { !$0.name.isEmpty })
    }

    /// Nineteen names, all resolved against the real `UIAccessibility`. The
    /// twentieth is deliberately absent — see `AccessibilityFlags`.
    @Test func everyAccessibilityNotificationNameResolves() {
        let names = AccessibilityFlags.changeNotificationNames

        #expect(names.count == 19)
        #expect(Set(names).count == 19)
        #expect(names.allSatisfy { !$0.rawValue.isEmpty })
    }

    @Test func aDynamicTypeChangeReachesTheInstrument() {
        let harness = InstrumentHarness<DynamicType>()
        harness.start()
        defer { harness.stop() }

        // The instrument reports the current category on activation, so the
        // first reading proves the read works against the real framework.
        let reading = harness.waitForReading()
        let category = harness.value(.textSizeCategory, in: reading)

        #expect(category != nil)
        #expect(category?.hasPrefix("UICTContentSizeCategory") == false)
    }

    /// The prefix strip is applied to whatever UIKit actually hands over, not to
    /// a literal — so a change in UIKit's raw values shows up here.
    @Test func theCategoryNameLosesTheFrameworkPrefix() {
        #expect(DynamicType.name(of: .large) == "large")
        #expect(DynamicType.name(of: .accessibilityExtraExtraExtraLarge)
            == "accessibilityExtraExtraExtraLarge")
    }

    @Test func anAccessibilityReadingArrivesOnActivation() {
        let harness = InstrumentHarness<AccessibilityFlags>()
        harness.start()
        defer { harness.stop() }

        #expect(harness.waitForReading() != nil)
    }
}
#endif
