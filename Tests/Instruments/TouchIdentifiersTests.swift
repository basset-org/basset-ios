@testable import Basset
import Foundation
import Testing

/// UIKit-free: `UITouch` has no reachable initializer, so a plain reference type stands in
/// for the object identity `TouchIdentifiers` actually keys on.
private final class Probe {}

struct TouchIdentifiersTests {
    @Test func eachBegunTouchGetsItsOwnId() {
        var ids = TouchIdentifiers()
        let first = ids.begin(ObjectIdentifier(Probe()))
        let second = ids.begin(ObjectIdentifier(Probe()))

        #expect(first != second)
    }

    @Test func endingATouchReturnsTheIdItBeganWith() {
        var ids = TouchIdentifiers()
        let touch = ObjectIdentifier(Probe())

        let begun = ids.begin(touch)
        #expect(ids.end(touch) == begun)
    }

    /// Teardown mid-gesture: an `.end` with no matching `.begin` is a gap, not a crash.
    @Test func endingAnUnknownTouchReturnsNil() {
        var ids = TouchIdentifiers()

        #expect(ids.end(ObjectIdentifier(Probe())) == nil)
    }

    @Test func aTouchCanOnlyBeEndedOnce() {
        var ids = TouchIdentifiers()
        let touch = ObjectIdentifier(Probe())

        _ = ids.begin(touch)
        _ = ids.end(touch)

        #expect(ids.end(touch) == nil)
    }

    /// `stopObserving` replaces the whole tracker with a fresh one — a local counter would
    /// restart at 1 and collide with an id a touch begun before the stop is still carrying.
    @Test func idsDoNotResetWhenTheTrackerIsReplaced() {
        var before = TouchIdentifiers()
        let earlier = before.begin(ObjectIdentifier(Probe()))

        var after = TouchIdentifiers()
        let later = after.begin(ObjectIdentifier(Probe()))

        #expect(later > earlier)
    }

    @Test func idsIncreaseAcrossManyTouches() {
        var ids = TouchIdentifiers()
        let assigned = (0 ..< 100).map { _ in ids.begin(ObjectIdentifier(Probe())) }

        #expect(assigned == assigned.sorted())
        #expect(Set(assigned).count == assigned.count)
    }
}
