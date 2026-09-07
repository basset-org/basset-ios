@testable import Basset
import Foundation
import Testing

/// Held for the test's life: a probe released at once would hand its address to the next one.
private final class Probe {}

struct TapBurstDetectorTests {
    private static let second: UInt64 = 1000000

    private let buttonProbe: Probe = .init()
    private let otherProbe: Probe = .init()

    private var button: ObjectIdentifier {
        ObjectIdentifier(buttonProbe)
    }

    private var other: ObjectIdentifier {
        ObjectIdentifier(otherProbe)
    }

    private static func detector() -> TapBurstDetector {
        TapBurstDetector(threshold: 3, withinMicroseconds: 5 * second, radiusPoints: 44)
    }

    private static func tap(
        on view: ObjectIdentifier?,
        x: Double = 100,
        y: Double = 200,
        at: UInt64
    ) -> TapBurstDetector.Tap {
        TapBurstDetector.Tap(
            view: view,
            viewClass: "UIButton",
            identifier: nil,
            label: nil,
            x: x,
            y: y,
            at: at
        )
    }

    @Test func theThirdTapOnOneControlCompletesABurst() {
        var detector = Self.detector()

        #expect(detector.record(Self.tap(on: button, at: 0)) == nil)
        #expect(detector.record(Self.tap(on: button, at: Self.second)) == nil)
        let burst = detector.record(Self.tap(on: button, x: 104, y: 198, at: 2 * Self.second))

        #expect(burst?.taps.count == 3)
        #expect(burst?.spanMicroseconds == 2 * Self.second)
        #expect(burst?.centre.x == 304.0 / 3)
    }

    @Test func laterTapsExtendTheBurstWithoutReportingItAgain() {
        var detector = Self.detector()
        for index in 0 ..< 3 {
            _ = detector.record(Self.tap(on: button, at: UInt64(index) * Self.second))
        }

        #expect(detector.record(Self.tap(on: button, at: 3 * Self.second)) == nil)

        let ended = detector.expire(now: 9 * Self.second)
        #expect(ended.count == 1)
        #expect(ended[0].taps.count == 4)
    }

    @Test func aDifferentControlStartsItsOwnBurst() {
        var detector = Self.detector()

        _ = detector.record(Self.tap(on: button, at: 0))
        _ = detector.record(Self.tap(on: other, at: Self.second))
        _ = detector.record(Self.tap(on: button, at: 2 * Self.second))
        #expect(detector.record(Self.tap(on: other, at: 3 * Self.second)) == nil)
        #expect(detector.record(Self.tap(on: button, at: 4 * Self.second)) != nil)
    }

    @Test func aTapFarFromTheCentreIsNotTheSameControl() {
        var detector = Self.detector()

        _ = detector.record(Self.tap(on: nil, at: 0))
        _ = detector.record(Self.tap(on: nil, at: Self.second))
        #expect(detector.record(Self.tap(on: nil, x: 300, at: 2 * Self.second)) == nil)
    }

    @Test func aGapLongerThanTheWindowEndsTheBurst() {
        var detector = Self.detector()

        _ = detector.record(Self.tap(on: button, at: 0))
        _ = detector.record(Self.tap(on: button, at: Self.second))
        #expect(detector.record(Self.tap(on: button, at: 8 * Self.second)) == nil)
        #expect(detector.record(Self.tap(on: button, at: 9 * Self.second)) == nil)
        #expect(detector.record(Self.tap(on: button, at: 10 * Self.second)) != nil)
    }

    @Test func anUnreportedBurstExpiresSilently() {
        var detector = Self.detector()

        _ = detector.record(Self.tap(on: button, at: 0))
        #expect(detector.expire(now: 20 * Self.second).isEmpty)
    }

    @Test func aReportedBurstOutlivesATapThatArrivesAfterItsWindow() {
        var detector = Self.detector()
        for index in 0 ..< 4 {
            _ = detector.record(Self.tap(on: button, at: UInt64(index) * Self.second))
        }

        #expect(detector.record(Self.tap(on: other, at: 9 * Self.second)) == nil)
        #expect(detector.record(Self.tap(on: button, at: 10 * Self.second)) == nil)

        let ended = detector.expire(now: 11 * Self.second)
        #expect(ended.count == 1)
        #expect(ended[0].taps.count == 4)
    }

    @Test func aTapStampedBeforeTheBurstBeganReadsAsAZeroSpan() {
        var detector = Self.detector()

        _ = detector.record(Self.tap(on: button, at: 5 * Self.second))
        _ = detector.record(Self.tap(on: button, at: 6 * Self.second))
        let burst = detector.record(Self.tap(on: button, at: 4 * Self.second))

        #expect(burst?.spanMicroseconds == 0)
    }
}

struct TouchTargetsTests {
    private let probe: Probe = .init()

    private var target: TouchTarget {
        TouchTarget(
            identity: ObjectIdentifier(probe),
            className: "UIButton",
            accessibilityIdentifier: nil,
            accessibilityLabel: "Switch Camera"
        )
    }

    @Test func aTouchEndsOnTheViewItBeganOn() {
        var targets = TouchTargets()
        let touch = ObjectIdentifier(Probe())

        targets.began(touch, on: target)

        #expect(targets.ended(touch) == target)
        #expect(targets.ended(touch) == nil)
    }

    @Test func aBeganWithNoViewForgetsAnyEarlierOne() {
        var targets = TouchTargets()
        let touch = ObjectIdentifier(Probe())

        targets.began(touch, on: target)
        targets.began(touch, on: nil)

        #expect(targets.ended(touch) == nil)
    }
}
