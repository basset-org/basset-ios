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

struct GestureTransitionsTests {
    /// Held, not made inline: a freed object's address is reused, and two identifiers made
    /// from throwaway objects can be the same one.
    private let first: NSObject = .init()
    private let second: NSObject = .init()

    private var one: ObjectIdentifier {
        ObjectIdentifier(first)
    }

    @Test func onlyAChangeOfStateIsAReading() {
        var transitions = GestureTransitions()

        let began = transitions.record(one, 1)
        let stillBegan = transitions.record(one, 1)
        let againBegan = transitions.record(one, 1)
        let ended = transitions.record(one, 3)

        #expect(began)
        #expect(!stillBegan)
        #expect(!againBegan)
        #expect(ended)
    }

    @Test func returningToPossibleIsATransitionAndForgetsTheRecognizer() {
        var transitions = GestureTransitions()
        _ = transitions.record(one, 1)

        let reset = transitions.record(one, GestureTransitions.possible)
        let remembered = transitions.lastState.isEmpty
        let resetAgain = transitions.record(one, GestureTransitions.possible)

        #expect(reset)
        #expect(remembered)
        #expect(!resetAgain)
    }

    /// A recognizer freed mid-gesture never reports `.possible`; the table stays bounded anyway.
    @Test func theOldestEntryIsEvictedOnceTheTableIsFull() {
        var transitions = GestureTransitions()
        let held = (0...GestureTransitions.capacity).map { _ in NSObject() }
        for recognizer in held {
            _ = transitions.record(ObjectIdentifier(recognizer), 1)
        }

        #expect(transitions.lastState.count == GestureTransitions.capacity)
        #expect(transitions.lastState[ObjectIdentifier(held[0])] == nil)
        #expect(transitions.lastState[ObjectIdentifier(held[1])] == 1)
        withExtendedLifetime(held) {}
    }

    @Test func recognizersAreTrackedApart() {
        var transitions = GestureTransitions()
        let other = ObjectIdentifier(second)
        _ = transitions.record(one, 2)

        let otherChanged = transitions.record(other, 2)
        let oneUnchanged = transitions.record(one, 2)

        #expect(otherChanged)
        #expect(!oneUnchanged)
    }
}
