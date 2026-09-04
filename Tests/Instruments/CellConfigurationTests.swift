@testable import Basset
import BassetEntityComponent
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

private func call(
    _ dataSource: String = "FeedDataSource",
    selector: String = "collectionView:cellForItemAtIndexPath:",
    item: UInt32 = 0,
    nanoseconds: UInt64
) -> CellCall {
    CellCall(
        dataSourceClass: dataSource,
        selector: selector,
        cellClass: "FeedCell",
        reuseIdentifier: "feed",
        section: 0,
        item: item,
        nanoseconds: nanoseconds
    )
}

struct CellConfigurationLedgerTests {
    private let feed = CellConfigurationLedger.Key(
        dataSourceClass: "FeedDataSource",
        selector: "collectionView:cellForItemAtIndexPath:"
    )

    @Test func theSlowestCallIsKeptPerDataSourceClassAndSelector() {
        var ledger = CellConfigurationLedger()
        ledger.record(call(item: 1, nanoseconds: 100))
        ledger.record(call(item: 2, nanoseconds: 300))
        ledger.record(call("SettingsDataSource", item: 9, nanoseconds: 50))

        let taken = ledger.take()

        #expect(taken.count == 2)
        #expect(taken[feed]?.item == 2)
        #expect(taken[feed]?.nanoseconds == 300)
    }

    @Test func takingEmptiesTheLedger() {
        var ledger = CellConfigurationLedger()
        ledger.record(call(nanoseconds: 1))
        _ = ledger.take()

        #expect(ledger.isEmpty)
        #expect(ledger.take().isEmpty)
    }

    @Test func theSlowestIsTheSlowestSingleCallNotTheLatest() {
        var ledger = CellConfigurationLedger()
        ledger.record(call(item: 4, nanoseconds: 900))
        ledger.record(call(item: 5, nanoseconds: 200))

        #expect(ledger.take()[feed]?.item == 4)
    }
}

struct CellCountersTests {
    private let feed = CellConfigurationLedger.Key(
        dataSourceClass: "FeedDataSource",
        selector: "collectionView:cellForItemAtIndexPath:"
    )

    @Test func everyCallIsCountedAndTheWindowRowCarriesTheSlowestNamedCall() {
        let counters = CellCounters(key: feed)
        counters.count(100)
        counters.count(300)
        counters.count(50)

        let row = counters.take(slowest: call(item: 2, nanoseconds: 300))
        let drained = counters.take(slowest: nil)

        #expect(row?.calls == 3)
        #expect(row?.totalNanoseconds == 450)
        #expect(row?.peakNanoseconds == 300)
        #expect(row?.slowest?.item == 2)
        #expect(drained == nil)
    }
}

struct InFlightTokensTests {
    @Test func aCallThatNeverArmedDoesNotTakeTheOuterCallsToken() {
        var tokens = InFlightTokens()
        _ = tokens.push(7, on: 1)
        _ = tokens.push(nil, on: 1)

        #expect(tokens.pop(on: 1) == nil)
        #expect(tokens.pop(on: 1) == 7)
    }

    @Test func aSkippedPushIsStillOnePopEvenAtTheOutermostCall() {
        var tokens = InFlightTokens()
        _ = tokens.push(nil, on: 1)
        _ = tokens.push(9, on: 1)

        #expect(tokens.pop(on: 1) == 9)
        #expect(tokens.pop(on: 1) == nil)
        #expect(tokens.pop(on: 1) == nil)
    }

    @Test func eachThreadPopsOnlyWhatItPushed() {
        var tokens = InFlightTokens()
        _ = tokens.push(1, on: 11)
        _ = tokens.push(2, on: 22)
        _ = tokens.push(3, on: 11)

        #expect(tokens.pop(on: 11) == 3)
        #expect(tokens.pop(on: 22) == 2)
        #expect(tokens.pop(on: 11) == 1)
        #expect(tokens.pop(on: 11) == nil)
        let allEmpty = tokens.byThread.values.allSatisfy(\.tokens.isEmpty)
        #expect(allEmpty)
    }

    /// A stack that emptied stays reserved: the next push on that thread allocates nothing.
    @Test func anEmptiedStackStaysReservedForItsThread() {
        var tokens = InFlightTokens()
        _ = tokens.push(1, on: 11)
        _ = tokens.pop(on: 11)

        #expect(tokens.byThread[11]?.tokens.isEmpty == true)
        #expect(tokens.byThread.count == 1)
    }

    @Test func aThreadPastTheDepthIsRefusedRatherThanGrown() {
        var tokens = InFlightTokens()
        let accepted = (1...UInt64(InFlightTokens.depth + 1)).map { tokens.push($0, on: 1) }

        #expect(accepted.filter(\.self).count == InFlightTokens.depth)
        #expect(accepted.last == false)
    }

    /// The refused call still leaves; its pop must not take the token of the call around it.
    @Test func aRefusedPushStillBalancesItsOwnPop() {
        var tokens = InFlightTokens()
        for token in 1...UInt64(InFlightTokens.depth) {
            _ = tokens.push(token, on: 1)
        }
        let refusedOuter = tokens.push(100, on: 1)
        let refusedInner = tokens.push(101, on: 1)

        #expect(!refusedOuter)
        #expect(!refusedInner)
        #expect(tokens.pop(on: 1) == nil)
        #expect(tokens.pop(on: 1) == nil)
        #expect(tokens.pop(on: 1) == UInt64(InFlightTokens.depth))
        let pushedAgain = tokens.push(102, on: 1)
        #expect(pushedAgain)
        #expect(tokens.pop(on: 1) == 102)
    }

    /// One delivery queue per camera: a leave on one must never take the other's token.
    @Test func twoThreadsEnteringAndLeavingTogetherEachGetTheirOwnTokenBack() {
        let shared = Mutex<InFlightTokens>(InFlightTokens())
        let popped = Mutex<[UInt64: UInt64?]>([:])
        let bothIn = DispatchGroup()
        let bothOut = DispatchGroup()
        let entered = DispatchSemaphore(value: 0)
        let mayLeave = DispatchSemaphore(value: 0)

        for token: UInt64 in [100, 200] {
            bothIn.enter()
            bothOut.enter()
            Thread {
                let me = pthread_mach_thread_np(pthread_self())
                _ = shared.withLock { $0.push(token, on: me) }
                entered.signal()
                bothIn.leave()
                mayLeave.wait()
                let back = shared.withLock { $0.pop(on: me) }
                popped.withLock { $0[token] = back }
                bothOut.leave()
            }.start()
        }
        entered.wait()
        entered.wait()
        #expect(bothIn.wait(timeout: .now() + 2) == .success)
        mayLeave.signal()
        mayLeave.signal()
        #expect(bothOut.wait(timeout: .now() + 2) == .success)

        #expect(popped.withLock { $0[100] } == 100)
        #expect(popped.withLock { $0[200] } == 200)
        let allEmpty = shared.withLock { $0.byThread.values.allSatisfy(\.tokens.isEmpty) }
        #expect(allEmpty)
    }
}

struct CallbackWatchTests {
    @Test func aCallbackIsDueOnceItsDeadlinePasses() {
        var watch = CallbackWatch()
        watch.enter(1, on: 1, at: 1000, threshold: 500)

        #expect(watch.due(at: 1499).isEmpty)
        #expect(watch.due(at: 1500).map(\.token) == [1])
    }

    @Test func leavingBeforeTheDeadlineDisarmsAndHandsBackNoFrames() {
        var watch = CallbackWatch()
        watch.enter(1, on: 1, at: 1000, threshold: 500)

        let frames = watch.leave(1)

        #expect(frames == nil)
        #expect(watch.isIdle)
        #expect(watch.due(at: 5000).isEmpty)
    }

    @Test func framesWalkedWhileArmedComeBackOnLeaveAndOnlyOnce() {
        var watch = CallbackWatch()
        watch.enter(7, on: 1, at: 0, threshold: 10)
        watch.capture([0xa, 0xb], for: 7)

        let first = watch.leave(7)
        let second = watch.leave(7)

        #expect(watch.isIdle)
        #expect(first == [0xa, 0xb])
        #expect(second == nil)
    }

    /// One queue per camera: a slow callback on one must not be forgotten because another
    /// queue's callback entered after it.
    @Test func callbacksOnTwoThreadsAreWatchedTogether() {
        var watch = CallbackWatch()
        watch.enter(1, on: 11, at: 0, threshold: 10)
        watch.enter(2, on: 22, at: 5, threshold: 10)

        let dueAtTwelve = watch.due(at: 12).map(\.token)
        let earliest = watch.earliestDeadlineNanoseconds
        let secondLeft = watch.leave(2)
        let stillDue = watch.due(at: 12).map(\.token)

        #expect(dueAtTwelve == [1])
        #expect(earliest == 10)
        #expect(secondLeft == nil)
        #expect(stillDue == [1])
    }

    @Test func aWalkForACallbackThatAlreadyLeftIsDropped() {
        var watch = CallbackWatch()
        watch.enter(1, on: 1, at: 0, threshold: 10)
        _ = watch.leave(1)
        watch.capture([0xdead], for: 1)

        #expect(watch.captured.isEmpty)
        #expect(watch.leave(1) == nil)
    }
}

struct CellConfigurationConfigTests {
    @Test func aZeroThresholdIsClampedRatherThanArmingEveryCall() {
        let instrument = CellConfiguration(config: .init(thresholdMs: 0))
        #expect(instrument.thresholdNanoseconds == 1000000)
    }

    @Test func theClampMatchesItsOwnDeclaredMetadataRange() throws {
        let field = try #require(
            InstrumentID.cellConfiguration.metadata.config.first { $0.key == "thresholdMs" }
        )
        let range = try #require(field.type.intRange)

        let lowest = CellConfiguration(config: .init(thresholdMs: .min))
        let highest = CellConfiguration(config: .init(thresholdMs: .max))
        #expect(lowest.thresholdNanoseconds == UInt64(range.lowerBound) * 1000000)
        #expect(highest.thresholdNanoseconds == UInt64(range.upperBound) * 1000000)
    }

    @Test func theDefaultIsHalfAFrameAtSixtyHertz() {
        #expect(CellConfiguration.defaultConfig.thresholdMs == 8)
    }

    @Test func theSlowCellStatusNamesTheSanitizerWhenOneIsLoaded() {
        #expect(CellConfiguration.notWalkedStatus(sanitizerLoaded: true).contains("sanitizer"))
        #expect(CellConfiguration.notWalkedStatus(sanitizerLoaded: false).contains("watchdog"))
    }
}

#if canImport(UIKit)
/// `@MainActor`: a collection view dequeues on the main thread and asserts otherwise.
@Suite(.serialized)
@MainActor
struct CellConfigurationWiringTests {
    private final class SlowDataSource: NSObject, UICollectionViewDataSource {
        nonisolated(unsafe) static var sleepSeconds: TimeInterval = 0

        func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
            1
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            Thread.sleep(forTimeInterval: Self.sleepSeconds)
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: "probe",
                for: indexPath
            )
        }
    }

    @Test func aSlowCellIsReportedWithTheStackWalkedInsideIt() {
        let harness = InstrumentHarness<CellConfiguration> {
            CellConfiguration(config: .init(thresholdMs: 5))
        }
        harness.registries
            .delegates(ObjectIdentifier(UICollectionView.self))
            .add(SlowDataSource.self)
        harness.start()
        defer { harness.stop() }

        let view = makeCollectionView()
        // Typed as the protocol: a direct call to a final Swift class never goes through
        // objc_msgSend, which is the only path the swizzle sits on.
        let dataSource: UICollectionViewDataSource = SlowDataSource()
        view.dataSource = dataSource
        SlowDataSource.sleepSeconds = 0.25
        _ = dataSource.collectionView(view, cellForItemAt: IndexPath(item: 0, section: 0))

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !harness.readings.contains(where: { $0.known == .cell }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let cell = harness.readings.first { $0.known == .cell }

        #expect(harness.value(.delegateClass, in: cell)?.contains("SlowDataSource") == true)
        #expect(harness.value(.reuseIdentifier, in: cell) == "probe")
        #expect(harness.value(.itemIndex, in: cell) == "0")
        #expect(cell?.components.contains { $0.known == .frameAddress } == true)
    }

    @Test func aFastCellIsOnlyCounted() {
        let harness = InstrumentHarness<CellConfiguration> {
            CellConfiguration(config: .init(thresholdMs: 500))
        }
        harness.registries
            .delegates(ObjectIdentifier(UICollectionView.self))
            .add(SlowDataSource.self)
        harness.start()
        defer { harness.stop() }

        let view = makeCollectionView()
        let dataSource: UICollectionViewDataSource = SlowDataSource()
        view.dataSource = dataSource
        SlowDataSource.sleepSeconds = 0
        _ = dataSource.collectionView(view, cellForItemAt: IndexPath(item: 3, section: 0))

        let window = harness.waitForReading(timeout: 4)

        #expect(window?.known == .cellProvider)
        #expect(harness.value(.delegateClass, in: window)?.contains("SlowDataSource") == true)
        #expect(harness.value(.occurrenceCount, in: window) == "1")
        #expect(harness.value(.itemIndex, in: window) == nil)
        #expect(!harness.readings.contains { $0.known == .cell })
    }

    private func makeCollectionView() -> UICollectionView {
        let view = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 200),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "probe")
        return view
    }
}
#endif
