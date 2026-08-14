@testable import Basset
import Foundation
import Testing

/// Serialized: `NotificationCenter.default` is process-wide, so concurrent harnesses cross-read.
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
        // A duration exists only if the will-save/did-save pairing on this context worked.
        #expect(reading?.components.contains { $0.id == .totalNanoseconds } == true)
    }

    /// A second context saving in between must not be paired with the first one's start.
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
        // The second context never announced a start, so it must not borrow the first one's clock.
        #expect(harness.value(.insertedCount, in: reading) == "1")
        #expect(reading?.components.contains { $0.id == .totalNanoseconds } == false)
    }
}

#if canImport(UIKit)
import UIKit

/// Simulator only — `canImport(UIKit)` is false on macOS, so this vanishes from `sdk_test`.
@Suite(.serialized)
struct UIKitWiringTests {
    /// A renamed property is a compile error; one answering nonsense shows up outside the set.
    @Test func everyAccessibilitySettingIsReadableFromTheRealFramework() {
        let settings = AccessibilityFlags.current

        #expect(settings.count == 20)
        #expect(Set(settings.map(\.name)).count == 20)
        #expect(settings.allSatisfy { !$0.name.isEmpty })
    }

    /// The twentieth setting has no notification name, deliberately — see `AccessibilityFlags`.
    @Test func everyAccessibilityNotificationNameResolves() {
        let names = AccessibilityFlags.changeNotificationNames

        #expect(names.count == 19)
        #expect(Set(names).count == 19)
        #expect(names.allSatisfy { !$0.rawValue.isEmpty })
    }

    /// A leaked observer keeps emitting into a request that has already ended.
    @Test func nothingArrivesAfterTheInstrumentStops() {
        let harness = InstrumentHarness<DynamicType>()
        harness.start()
        harness.waitForReading()
        harness.stop()
        harness.forget()

        NotificationCenter.default.post(
            name: UIContentSizeCategory.didChangeNotification,
            object: nil,
            userInfo: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(harness.readings.isEmpty)
    }

    @Test func aDynamicTypeChangeReachesTheInstrument() {
        let harness = InstrumentHarness<DynamicType>()
        harness.start()
        defer { harness.stop() }

        // Reported on activation, so the first reading proves the read against the real framework.
        let reading = harness.waitForReading()

        if let category = harness.value(.textSizeCategory, in: reading) {
            #expect(category.hasPrefix("UICTContentSizeCategory") == false)
        } else {
            // A runner with no application object gets the refusal, not a nil-messaged blank.
            let status = harness.value(.mechanismStatus, in: reading)
            #expect(status?.hasPrefix("unavailable") == true)
        }
    }

    /// The prefix strip runs against what UIKit actually hands over, not a literal.
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
