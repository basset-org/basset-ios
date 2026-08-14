@testable import Basset
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

/// Notification names come from real symbols, not string literals, so a typo is a compile error.
@Suite(.serialized)
struct SystemWiringTests {
    @Test func thermalStateIsReportedTheMomentItIsAskedFor() {
        let harness = InstrumentHarness<ThermalState>()
        harness.start()
        defer { harness.stop() }

        // Nothing is posted — the instrument promises a reading on activation regardless.
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

        // `thermalStateDidChangeNotification` only fires on a real move, so every one is emitted.
        #expect(harness.value(.thermalState, in: harness.readings.first) != nil)
    }

    /// Aggregated behind a one-second flush — the only test proving `flush(every:)` fires.
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
        // The app-directed warning and the system pressure source are different facts.
        #expect(harness.value(.memoryPressureScope, in: reading) == "app")
        #expect(reading?.components.contains { $0.id == .memoryUsedBytes } == true)
    }

    /// On the main actor — off it, `capture()`'s read can land after the notification below.
    @MainActor
    @Test func theAppStateIsReportedOnActivationAndFollowsTheApp() {
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

        // Without a baseline, a later row would say a status changed and never say what from.
        #expect(harness.waitForReading() != nil)
    }

    /// Opens a real memory-mapped record; a first run has nothing before it, and says so.
    @Test func theRunRecordOpensAndReportsWhateverPrecededIt() {
        let harness = InstrumentHarness<LastRunEnded>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading()
        #expect(reading != nil)
        // A verdict about the previous run, or a statement there was none — never silence.
        let said = reading?.components.contains {
            $0.id == .exitReason || $0.id == .mechanismStatus
        }
        #expect(said == true)
    }
    #endif
}
