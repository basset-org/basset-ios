@testable import Basset
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// The instruments that listen to the system rather than to a framework the app
/// created, driven the same way: activate, provoke, assert something arrived.
///
/// Their notification names come from real symbols rather than string literals,
/// so a typo is a compile error and the `storage` trap cannot recur here. What is
/// still untested without these is everything around the name — whether `observe`
/// registers at all, whether the emit path reaches a sink, whether a reading
/// arrives on activation as the instrument claims, and whether `stopObserving`
/// actually stops it.
@Suite(.serialized)
struct SystemWiringTests {
    @Test func thermalStateIsReportedTheMomentItIsAskedFor() {
        let harness = InstrumentHarness<ThermalState>()
        harness.start()
        defer { harness.stop() }

        // Nothing is posted: the instrument promises a reading on activation, and
        // an instrument that only speaks when the state changes would report
        // nothing for a device that never gets warm.
        let state = harness.value(.thermalState, in: harness.waitForReading())
        #expect(["nominal", "fair", "serious", "critical"].contains(state ?? ""))
    }

    @Test func aThermalChangeReachesTheInstrument() {
        let harness = InstrumentHarness<ThermalState>()
        harness.start()
        defer { harness.stop() }
        harness.waitForReading()
        harness.forget()

        NotificationCenter.default.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        // Emitted on every notification rather than only on a change, and that is
        // correct here: `thermalStateDidChangeNotification` fires only when the
        // state really moved, so suppressing a repeat would discard a real
        // transition back to a level the device had been at before.
        #expect(harness.value(.thermalState, in: harness.readings.first) != nil)
    }

    /// Aggregated behind a one-second flush, so this is also the only test that
    /// proves a `flush(every:)` timer reaches a sink at all.
    @Test func coreDataChangesAreCountedAndFlushed() {
        let harness = InstrumentHarness<CoreDataChanges>()
        harness.start()
        defer { harness.stop() }

        for _ in 0 ..< 3 {
            NotificationCenter.default.post(
                name: CoreDataNotifications.objectsChanged,
                object: NSObject(),
                userInfo: ["updated": NSSet(array: [1, 2])]
            )
        }

        let reading = harness.waitForReading(timeout: 4)
        #expect(harness.value(.occurrenceCount, in: reading) == "3")
        #expect(harness.value(.updatedCount, in: reading) == "6")
    }

    #if canImport(UIKit)
    @Test func aMemoryWarningReachesTheInstrument() {
        let harness = InstrumentHarness<MemoryPressure>()
        harness.start()
        defer { harness.stop() }

        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        let reading = harness.waitForReading()
        #expect(harness.value(.memoryPressureLevel, in: reading) == "warning")
        // The app-directed warning and the system pressure source are two
        // different facts, and the reading has to say which one spoke.
        #expect(harness.value(.memoryPressureScope, in: reading) == "app")
        // The ledger is read at the edge, so a footprint arrives with it.
        #expect(reading?.components.contains { $0.id == .memoryUsedBytes } == true)
    }

    @Test func theAppStateIsReportedOnActivationAndFollowsTheApp() {
        // `start` establishes presence before any request can arrive, and this
        // instrument now reports what the app is actually doing rather than
        // assuming the foreground. The notification stands in for a launch that
        // reached the front, so the test does not depend on whatever the host
        // app running it happens to be doing.
        ApplicationPresence.capture()
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        let harness = InstrumentHarness<AppState>()
        harness.start()
        defer { harness.stop() }

        #expect(harness.value(.appState, in: harness.waitForReading()) == "foreground")
        harness.forget()

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        #expect(harness.value(.appState, in: harness.readings.first) == "background")
    }

    /// The gap a capture cannot otherwise explain: how long the app was away.
    /// Measured from the background transition to the next activation.
    @Test func returningToTheForegroundReportsHowLongTheAppWasAway() {
        let harness = InstrumentHarness<AppState>()
        harness.start()
        defer { harness.stop() }
        harness.waitForReading()

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        harness.forget()
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let resumed = harness.readings.first { entity in
            entity.components
                .contains { $0.id == .appState && $0.value.rendered == "resumed" }
        }
        #expect(resumed != nil)
        #expect(resumed?.components.contains { $0.id == .totalNanoseconds } == true)
    }

    @Test func permissionsAreReReadWhenTheAppComesBack() {
        let harness = InstrumentHarness<PermissionChanges>()
        harness.start()
        defer { harness.stop() }

        // The baseline arrives on activation; without it a later row would say a
        // status changed to something and never say what from.
        #expect(harness.waitForReading() != nil)
    }

    /// Opens a real memory-mapped record and starts its stamping thread, so this
    /// exercises the mechanism rather than the verdict rules the other tests
    /// cover. A first run has nothing before it, and saying so is the reading.
    @Test func theRunRecordOpensAndReportsWhateverPrecededIt() {
        let harness = InstrumentHarness<LastRunEnded>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading()
        #expect(reading != nil)
        // Either a verdict about a previous run or an explicit statement that
        // there was none — never silence.
        let said = reading?.components.contains {
            $0.id == .exitReason || $0.id == .mechanismStatus
        }
        #expect(said == true)
    }
    #endif
}
