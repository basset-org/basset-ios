@testable import Basset
import Foundation
import Testing

struct CallerStackTests {
    @Test func aStackIsWalkedWithoutSuspendingAnything() {
        let frames = CallerStack.here()
        #expect(!frames.isEmpty)
        #expect(frames.count <= CallerStack.maxFrames)
        #expect(frames.allSatisfy { $0 != 0 })
    }

    @Test func theWalkIsBoundedNoMatterHowDeepTheStackRuns() {
        func descend(_ remaining: Int) -> [UInt64] {
            remaining == 0 ? CallerStack.here() : descend(remaining - 1)
        }

        let walked = descend(200)
        #expect(!walked.isEmpty)
        #expect(walked.count <= CallerStack.maxFrames)
    }

    @Test func aTrackedObjectRemembersWhereItWasFirstSeenFrom() {
        final class Tracked {}

        let registry = WeakRegistry<Tracked>()
        let held = Tracked()
        let instance = registry.add(held)

        let callers = registry.callers(ofInstance: instance)
        #expect(!callers.isEmpty)
        #expect(callers.count <= CallerStack.maxFrames)
    }

    @Test func twoObjectsOfOneClassCarryTheirOwnCallers() {
        final class Tracked {}

        let registry = WeakRegistry<Tracked>()
        let first = Tracked()
        let second = Tracked()

        let one = registry.add(first)
        let two = registry.add(second)

        #expect(one != two)
        #expect(!registry.callers(ofInstance: one).isEmpty)
        #expect(!registry.callers(ofInstance: two).isEmpty)
    }

    @Test func anInstanceNobodyTrackedHasNoCallers() {
        final class Tracked {}

        #expect(WeakRegistry<Tracked>().callers(ofInstance: 9999).isEmpty)
    }
}
