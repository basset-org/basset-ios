@testable import Basset
import BassetECS
import Foundation
import Testing

/// Layer 0: the shared machinery, tested once against a controlled ObjC class
/// rather than per instrument.
/// A swizzle is permanent and process-wide by design, so each test gets its own
/// class. Sharing one would let an earlier test's hook count toward a later one.
@objc private class Subject: NSObject {
    @objc dynamic var counter = 0
    private(set) var ran = 0

    @objc dynamic func work() {
        ran += 1
    }

    @objc dynamic func take(_ flag: Bool) {
        ran += flag ? 1 : 0
    }

    @objc dynamic func accept(_ argument: AnyObject?) {
        if argument != nil {
            ran += 1
        }
    }
}

@objc private class ReleaseRaceSubject: NSObject {
    @objc dynamic func work() {}
}

@objc private class ChainedSubject: Subject {}
@objc private class SharedSubject: Subject {}
@objc private class RestartedSubject: Subject {}
@objc private class ReleasedSubject: Subject {}
@objc private class SiblingSubject: Subject {}
@objc private class DoubledSubject: Subject {}
@objc private class ArgumentSubject: Subject {}
@objc private class TimingSubject: Subject {}
@objc private class BirthSubject: Subject {}
@objc private class SelfBirthSubject: Subject {}
@objc private class UnhookedSubject: Subject {}
@objc private class MismatchSubject: Subject {}
@objc private class MatchedSubject: Subject {}

@objc private class Caught: NSObject {}

/// A two-object setter, the shape `-setSampleBufferDelegate:queue:` has.
@objc private class TwoObjectSubject: NSObject {
    private(set) var ran = 0

    @objc dynamic func set(_ delegate: AnyObject?, queue: AnyObject?) {
        ran += 1
    }
}

/// A sample-buffer delegate written the way an app writes one: the frame
/// callback implemented, the drop callback absent.
@objc private class BufferSubject: NSObject {
    private(set) var ran = 0

    @objc dynamic func captureOutput(
        _ output: AnyObject?,
        didOutputSampleBuffer buffer: UnsafeRawPointer?,
        fromConnection connection: AnyObject?
    ) {
        ran += 1
    }
}

@objc private class SilentSubject: NSObject {}

@objc private class ObjectBufferSubject: NSObject {
    @objc dynamic func captureOutput(
        _ output: AnyObject?,
        didOutputSampleBuffer buffer: AnyObject?,
        fromConnection connection: AnyObject?
    ) {}
}

/// A factory the way the frameworks write them: a class method that builds the
/// thing and hands it back. AVCaptureSession is caught at a wiring call, but a
/// URLSession is only ever reachable through one of these.
@objc private class Maker: NSObject {
    @objc dynamic static func make() -> Caught {
        Caught()
    }

    @objc dynamic static func make(
        _ first: AnyObject?,
        second: AnyObject?,
        third: AnyObject?
    ) -> Caught {
        Caught()
    }

    @objc dynamic func makeOne() -> Caught {
        Caught()
    }

    @objc dynamic func doNothing() {}
}

@objc private class TypeFactorySubject: Maker {}
@objc private class InstanceFactorySubject: Maker {}
@objc private class ThreeArgFactorySubject: Maker {}
@objc private class WrongKindSubject: Maker {}

/// A reading that reports a state, emitted only when the state differs. The
/// mechanisms behind these instruments repeat themselves — KVO fires on every
/// set, and two UIKit notifications describe one transition — so the repeat is
/// the mechanism talking rather than the app changing.
struct ChangeGatedEmissionTests {
    @Test func anUnchangedStateIsNotSentTwice() {
        nonisolated(unsafe) var sent = [Entity]()
        let context = context { sent.append($0) }

        context.emitIfChanged { $0.put(.appState("foreground")) }
        context.emitIfChanged { $0.put(.appState("foreground")) }

        #expect(sent.count == 1)
    }

    @Test func aChangedStateIsSent() {
        nonisolated(unsafe) var sent = [Entity]()
        let context = context { sent.append($0) }

        context.emitIfChanged { $0.put(.appState("foreground")) }
        context.emitIfChanged { $0.put(.appState("background")) }
        context.emitIfChanged { $0.put(.appState("foreground")) }

        #expect(sent.count == 3, "returning to a state is a change, not a repeat")
    }

    /// Two sessions alternating are not repeats of each other. Suppressing on
    /// the entity alone would drop every second reading.
    @Test func twoSubjectsAreTrackedApart() {
        nonisolated(unsafe) var sent = [Entity]()
        let context = context { sent.append($0) }

        context.emitIfChanged(of: "camera-a") { $0.put(.appState("running")) }
        context.emitIfChanged(of: "camera-b") { $0.put(.appState("running")) }
        context.emitIfChanged(of: "camera-a") { $0.put(.appState("running")) }

        #expect(sent.count == 2, "each subject is judged against its own last reading")
    }

    @Test func whatWasSaidIsForgottenWhenTheInstrumentStops() {
        nonisolated(unsafe) var sent = [Entity]()
        let context = context { sent.append($0) }

        context.emitIfChanged { $0.put(.appState("foreground")) }
        context.teardown()
        context.emitIfChanged { $0.put(.appState("foreground")) }

        #expect(
            sent.count == 2,
            "the first reading of a new activation re-establishes the state"
        )
    }

    @Test func twoReadingsSayingTheSameThingShareAFingerprint() {
        var first = Entity(.appLifecycle, capturedAt: 1)
        first.add(.appState("foreground"))
        var second = Entity(.appLifecycle, capturedAt: 999)
        second.add(.appState("foreground"))
        var different = Entity(.appLifecycle, capturedAt: 1)
        different.add(.appState("background"))

        #expect(
            first.fingerprint == second.fingerprint,
            "when it was said is not what it says"
        )
        #expect(first.fingerprint != different.fingerprint)
    }

    private func context(_ sink: @escaping @Sendable (Entity) -> Void) -> Context {
        let status = AtomicStatus()
        status.activate()
        return Context(
            instrumentName: "lifecycle.app.state",
            defaultEntity: .appLifecycle,
            status: status,
            swizzle: Swizzle(),
            registries: Registries(),
            timerQueue: DispatchQueue(label: "test.flush"),
            sink: sink
        )
    }
}

struct SwizzleTests {
    /// A thunk runs on whichever thread the app called the hooked method on,
    /// while deactivation drops observers from the runner queue. Reading the
    /// list unguarded retained a buffer the release had already freed.
    @Test func callingAHookWhileObserversAreReleasedIsSafe() {
        let subject = ReleaseRaceSubject()
        let handles = (0 ..< 8).map { _ in Swizzle() }
        for handle in handles {
            _ = handle.after(ReleaseRaceSubject.self, #selector(ReleaseRaceSubject.work)) {
                _ in
            }
        }

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            if index % 4 == 3 {
                handles[index % handles.count].releaseObservers()
            } else {
                for _ in 0 ..< 2000 {
                    subject.work()
                }
            }
        }
    }

    @Test func theOriginalStillRunsAndTheObserverSeesIt() {
        let swizzle = Swizzle()
        var seen = 0

        #expect(
            swizzle.after(ChainedSubject.self, #selector(Subject.work)) { _ in seen += 1 }
                == .installed
        )

        let subject = ChainedSubject()
        subject.work()

        #expect(
            subject.ran == 1,
            "the original implementation is chained, never replaced"
        )
        #expect(seen == 1)
    }

    @Test func twoInstrumentsOnOneSelectorInstallOnceAndBothRun() {
        let swizzle = Swizzle()
        var first = 0
        var second = 0

        #expect(
            swizzle.after(SharedSubject.self, #selector(Subject.work)) { _ in first += 1 }
                == .installed
        )
        // A second Swizzle instance, to prove the table that matters is the
        // process's rather than the object's.
        #expect(
            Swizzle()
                .after(SharedSubject.self, #selector(Subject.work)) { _ in second += 1 }
                == .joinedExisting
        )
        SharedSubject().work()

        #expect(first == 1)
        #expect(second == 1)
    }

    /// An instrument is enabled, allowed to expire, and asked for again.
    /// Nothing un-swizzles between the two, so the second activation reaches a
    /// site that already exists — and before observers were released on
    /// teardown, it left two copies of the same closure on it and reported every
    /// call twice.
    @Test func anOwnerActivatedTwiceIsStillToldOnce() {
        let swizzle = Swizzle()
        var seen = 0
        let observe = {
            swizzle
                .after(RestartedSubject.self, #selector(Subject.work)) { _ in seen += 1 }
        }

        #expect(observe() == .installed)
        RestartedSubject().work()
        #expect(seen == 1)

        swizzle.releaseObservers()
        #expect(observe() == .joinedExisting)
        RestartedSubject().work()

        #expect(
            seen == 2,
            "the second activation replaces its observer rather than adding one"
        )
    }

    @Test func aReleasedOwnerHearsNothingAndTheOriginalStillRuns() {
        let swizzle = Swizzle()
        var seen = 0

        #expect(
            swizzle
                .after(ReleasedSubject.self, #selector(Subject.work)) { _ in seen += 1 }
                == .installed
        )
        swizzle.releaseObservers()

        let subject = ReleasedSubject()
        subject.work()

        #expect(seen == 0)
        #expect(
            subject.ran == 1,
            "releasing an observer leaves the hook chaining the original"
        )
    }

    @Test func releasingOneOwnerLeavesTheOtherAttached() {
        let leaving = Swizzle()
        let staying = Swizzle()
        var left = 0
        var stayed = 0

        #expect(
            leaving.after(SiblingSubject.self, #selector(Subject.work)) { _ in left += 1 }
                == .installed
        )
        #expect(
            staying
                .after(SiblingSubject.self, #selector(Subject.work)) { _ in stayed += 1 }
                == .joinedExisting
        )
        leaving.releaseObservers()
        SiblingSubject().work()

        #expect(left == 0)
        #expect(stayed == 1)
    }

    /// A load-time chokepoint registers births for every instrument, so one
    /// handle holds several observers on one selector. Releasing takes all of
    /// that handle's and none of anyone else's.
    @Test func oneOwnerHoldingTwoObserversReleasesBoth() {
        let swizzle = Swizzle()
        var first = 0
        var second = 0

        #expect(
            swizzle
                .after(DoubledSubject.self, #selector(Subject.work)) { _ in first += 1 }
                == .installed
        )
        #expect(
            swizzle
                .after(DoubledSubject.self, #selector(Subject.work)) { _ in second += 1 }
                == .joinedExisting
        )
        DoubledSubject().work()
        #expect(first == 1)
        #expect(second == 1)

        swizzle.releaseObservers()
        DoubledSubject().work()

        #expect(first == 1)
        #expect(second == 1)
    }

    @Test func aMissingClassOrSelectorIsANoOpRatherThanACrash() {
        let swizzle = Swizzle()

        #expect(swizzle.after(nil, #selector(Subject.work)) { _ in } == .classMissing)
        #expect(
            swizzle
                .after(UnhookedSubject.self, Selector(("nothingImplementsThis"))) { _ in }
                == .selectorMissing
        )
    }

    @Test func argumentsReachTheObserver() {
        let swizzle = Swizzle()
        var flags = [Bool]()

        _ = swizzle.after(ArgumentSubject.self, #selector(Subject.take(_:))) { (
            _,
            flag: Bool
        ) in
            flags.append(flag)
        }

        let subject = ArgumentSubject()
        subject.take(true)
        subject.take(false)

        #expect(flags == [true, false])
        #expect(subject.ran == 1)
    }

    /// The crash a real device found: `-[AVCaptureSession addOutput:]` hooked
    /// with the no-argument shape chained the original through
    /// `(AnyObject, Selector) -> Void`, so AVFoundation read its output from a
    /// register nothing had set and died on 0x20. Refusing the install turns that
    /// into a missing instrument instead of a crash inside the framework.
    @Test func aShapeThatDoesNotMatchTheSelectorIsRefused() {
        let swizzle = Swizzle()

        #expect(
            swizzle.after(MismatchSubject.self, #selector(Subject.accept(_:))) { _ in }
                == .signatureMismatch(expected: 2, actual: 3),
            "accept: takes an argument, so the no-argument shape cannot chain it"
        )
        #expect(
            swizzle.after(MismatchSubject.self, #selector(Subject.work)) { (
                _,
                _: AnyObject?
            ) in }
                == .signatureMismatch(expected: 3, actual: 2),
            "work takes none, so the one-argument shape cannot chain it"
        )
    }

    @Test func theMatchingShapeStillInstalls() {
        let swizzle = Swizzle()
        var seen = 0

        #expect(
            swizzle.after(MatchedSubject.self, #selector(Subject.accept(_:))) {
                (_, _: AnyObject?) in seen += 1
            } == .installed
        )

        let subject = MatchedSubject()
        subject.accept(Caught())

        #expect(subject.ran == 1, "the original ran with its argument intact")
        #expect(seen == 1)
    }

    @Test func timingMeasuresTheChainedCall() {
        let swizzle = Swizzle()
        var elapsed = [UInt64]()

        _ = swizzle
            .timing(TimingSubject.self, #selector(Subject.work)) { _, nanoseconds in
                elapsed.append(nanoseconds)
            }

        let subject = TimingSubject()
        subject.work()

        #expect(subject.ran == 1)
        #expect(elapsed.count == 1)
    }
}

struct FactorySwizzleTests {
    private static let didOutput: Selector = .init(
        "captureOutput:didOutputSampleBuffer:fromConnection:"
    )
    private static let didDrop: Selector = .init(
        "captureOutput:didDropSampleBuffer:fromConnection:"
    )

    @Test func aClassFactoryHandsOverWhatItMade() {
        let swizzle = Swizzle()
        var made = [AnyObject]()

        #expect(
            swizzle.afterFactory(
                TypeFactorySubject.self, #selector(Maker.make as () -> Caught),
                kind: .type
            ) { _, result in
                if let result {
                    made.append(result)
                }
            } == .installed
        )

        let returned = TypeFactorySubject.make()

        #expect(made.count == 1)
        #expect(made.first === returned, "the caller gets the object the original made")
    }

    /// The failure this whole shape exists to avoid: dropping the return value
    /// would hand the caller whatever was in the register.
    @Test func theCallerStillReceivesTheObject() {
        let swizzle = Swizzle()
        _ = swizzle.afterFactory(
            InstanceFactorySubject.self, #selector(Maker.makeOne)
        ) { _, _ in }

        let maker = InstanceFactorySubject()
        let first = maker.makeOne()
        let second = maker.makeOne()

        #expect(first !== second, "each call still produces its own object")
    }

    @Test func aThreeObjectFactoryPassesItsArgumentsThrough() {
        let swizzle = Swizzle()
        var seen = [(AnyObject?, AnyObject?, AnyObject?, AnyObject?)]()

        #expect(
            swizzle.afterFactory(
                ThreeArgFactorySubject.self,
                #selector(Maker.make(_:second:third:)),
                takingThreeObjects: (),
                kind: .type
            ) { _, first, second, third, result in
                seen.append((first, second, third, result))
            } == .installed
        )

        let a = Caught()
        let b = Caught()
        let returned = ThreeArgFactorySubject.make(a, second: b, third: nil)

        #expect(seen.count == 1)
        #expect(seen.first?.0 === a)
        #expect(seen.first?.1 === b)
        #expect(seen.first?.2 == nil)
        #expect(seen.first?.3 === returned)
    }

    /// A class method lives on the metaclass, so reaching for it through the
    /// class itself finds nothing at all.
    @Test func aClassMethodIsNotFoundOnTheInstanceSide() {
        let swizzle = Swizzle()

        #expect(
            swizzle.afterFactory(
                WrongKindSubject.self, #selector(Maker.make as () -> Caught),
                kind: .instance
            ) { _, _ in } == .selectorMissing
        )
    }

    /// The other direction: a factory shape would return an object the original
    /// never made, so a void method has to be refused too.
    @Test func aVoidMethodIsRefusedByAFactoryShape() {
        let swizzle = Swizzle()

        #expect(
            swizzle
                .afterFactory(WrongKindSubject.self, #selector(Maker.doNothing)) { _, _ in
                }
                == .returnMismatch(expected: "@", actual: "v")
        )
    }

    /// The guard that caught the addOutput: crash, from the other direction: a
    /// void shape must still refuse a method that returns something.
    @Test func aReturningMethodIsRefusedByAVoidShape() {
        let swizzle = Swizzle()

        #expect(
            swizzle.after(InstanceFactorySubject.self, #selector(Maker.makeOne)) { _ in }
                == .returnMismatch(expected: "v", actual: "@")
        )
    }

    @Test func bothArgumentsOfATwoObjectSetterReachTheObserver() {
        let swizzle = Swizzle()
        var seen: (AnyObject?, AnyObject?)?

        #expect(
            swizzle.after(
                TwoObjectSubject.self,
                #selector(TwoObjectSubject.set(_:queue:)),
                takingTwoObjects: ()
            ) { _, first, second in seen = (first, second) } == .installed
        )

        let subject = TwoObjectSubject()
        let delegate = Caught()
        let queue = Caught()
        subject.set(delegate, queue: queue)

        #expect(
            subject.ran == 1,
            "the original implementation is chained, never replaced"
        )
        #expect(seen?.0 === delegate)
        #expect(seen?.1 === queue)
    }

    @Test func aSampleBufferCallbackTheClassWroteIsChained() {
        let swizzle = Swizzle()
        var seen = 0
        var buffer: UnsafeRawPointer?

        #expect(
            swizzle
                .sampleBufferCallback(BufferSubject.self,
                                      Self.didOutput)
                { _, _, got, _ in
                    seen += 1
                    buffer = got
                } == .installed
        )

        let subject = BufferSubject()
        let sample = UnsafeRawPointer(bitPattern: 0x1000)
        subject.captureOutput(nil, didOutputSampleBuffer: sample, fromConnection: nil)

        #expect(subject.ran == 1, "the delegate still receives its own frames")
        #expect(seen == 1)
        #expect(buffer == sample, "the buffer reaches the observer without being bridged")
    }

    /// The case the drop callback exists for: a delegate that never wrote the
    /// method does not respond to it, so the framework never sends it. Defining
    /// it is what makes the frames it would have reported observable at all.
    @Test func aSampleBufferCallbackTheClassLacksIsDefined() {
        let swizzle = Swizzle()
        var seen = 0

        #expect(
            SilentSubject().responds(to: Self.didDrop) == false,
            "nothing answers this selector before the hook"
        )
        #expect(
            swizzle.sampleBufferCallback(SilentSubject.self, Self.didDrop) { _, _, _, _ in
                seen += 1
            } == .implemented
        )

        let subject = SilentSubject()
        #expect(subject.responds(to: Self.didDrop))

        let implementation = class_getMethodImplementation(
            SilentSubject.self,
            Self.didDrop
        )
        let call = unsafeBitCast(
            implementation,
            to: (@convention(c) (
                AnyObject, Selector, AnyObject?, UnsafeRawPointer?, AnyObject?
            ) -> Void).self
        )
        call(subject, Self.didDrop, nil, nil, nil)

        #expect(seen == 1, "a method with nothing to chain still runs its observers")
    }

    /// The buffer slot is the one the shape exists to protect. A selector
    /// carrying an object there would have the thunk retain and release it.
    @Test func aSampleBufferShapeRefusesAnObjectWhereTheBufferGoes() {
        let swizzle = Swizzle()

        #expect(
            swizzle.sampleBufferCallback(ObjectBufferSubject.self, Self.didOutput) {
                _, _, _, _ in
            } == .argumentKindMismatch(shape: "sampleBufferCallback")
        )
    }
}

struct HookTableTests {
    @Test func aChokepointRegistersWhatPassesThroughIt() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.catchBirths(
            of: Caught.self,
            at: #selector(Subject.accept(_:)),
            on: BirthSubject.self
        )

        let born = Caught()
        BirthSubject().accept(born)

        #expect(registries.registry(Caught.self).all.count == 1)
    }

    @Test func aChokepointCanRegisterTheReceiverItself() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.catchSelf(
            of: SelfBirthSubject.self,
            at: #selector(Subject.work),
            on: SelfBirthSubject.self
        )

        let subject = SelfBirthSubject()
        subject.work()

        #expect(registries.registry(SelfBirthSubject.self).all.count == 1)
    }
}

struct WeakRegistryTests {
    @Test func aDeadEntryVanishes() {
        let registry = WeakRegistry<Caught>()
        autoreleasepool {
            let transient = Caught()
            registry.add(transient)
            #expect(registry.count == 1)
        }
        #expect(registry.count == 0, "basset never retains an app object")
    }

    /// A follower saw the object while there was nothing on it worth hooking,
    /// and `add` says nothing about one it already holds — so a video output
    /// handed to a session before it is told who receives its frames was
    /// instrumented once, uselessly, and never again.
    @Test func announcingAKnownObjectTellsTheFollowersAgain() {
        let registry = WeakRegistry<Caught>()
        let caught = Caught()
        registry.add(caught)

        var attached = [Caught]()
        registry.attachAndFollow { object, _ in attached.append(object) }
        #expect(attached.count == 1)

        registry.add(caught)
        #expect(attached.count == 1, "adding what is already held stays silent")

        registry.announce(caught)
        #expect(attached.count == 2, "announcing it does not")
        #expect(attached.last === caught)
    }

    /// Both orders reach the follower through one call: the app may set the
    /// delegate before the output is ever added, and an announcement of
    /// something unknown is that object arriving.
    @Test func announcingAnUnknownObjectAddsIt() {
        let registry = WeakRegistry<Caught>()
        var attached = [Caught]()
        registry.attachAndFollow { object, _ in attached.append(object) }

        let caught = Caught()
        registry.announce(caught)

        #expect(registry.count == 1)
        #expect(attached.count == 1)
    }

    /// The number survives what the address does not. A sample kept under a
    /// released controller's address is one the next allocation at that address
    /// inherits, and inheriting a sample reads as "nothing changed".
    @Test func theInstanceNumberIsNotReusedWhenAnAddressIs() {
        let registry = WeakRegistry<Caught>()
        var first: UInt32?
        autoreleasepool {
            let transient = Caught()
            registry.add(transient)
            first = registry.tracked.first?.instance
        }

        let replacement = Caught()
        registry.add(replacement)

        #expect(first != nil)
        #expect(registry.tracked.first?.instance != first)
    }

    @Test func addingTheSameObjectTwiceKeepsOneEntry() {
        let registry = WeakRegistry<Caught>()
        let caught = Caught()
        registry.add(caught)
        registry.add(caught)

        #expect(registry.count == 1)
    }

    /// The gap a real device found first: an instrument activated while the app
    /// runs walks the registry once, and every object the app builds afterwards —
    /// a capture session made when the camera screen opens, which is most of them
    /// — arrives to nobody.
    @Test func followingReachesObjectsBornAfterActivation() {
        let registry = WeakRegistry<Caught>()
        let before = Caught()
        registry.add(before)

        var attached = [Caught]()
        registry.attachAndFollow { caught, _ in attached.append(caught) }
        #expect(attached.count == 1, "what was already caught")

        let after = Caught()
        registry.add(after)

        #expect(attached.count == 2, "and what arrives next")
        #expect(attached.last === after)
    }

    @Test func oneInstrumentUnfollowingLeavesItsSiblingsAttached() {
        let registry = WeakRegistry<Caught>()
        var first = 0
        var second = 0

        let token = registry.attachAndFollow { _, _ in first += 1 }
        registry.attachAndFollow { _, _ in second += 1 }

        registry.add(Caught())
        registry.stopFollowing(token)
        registry.add(Caught())

        #expect(first == 1, "stopped after the first arrival")
        #expect(second == 2, "the sibling still hears about both")
    }

    /// Several objects of one class are observed at once, so a reading has to say
    /// which. The registry numbers what it catches, per run, so every Shape A
    /// instrument gets identity without inventing its own.
    @Test func everyCaughtObjectGetsItsOwnNumber() {
        let registry = WeakRegistry<Caught>()
        var numbers = [UInt32]()
        registry.attachAndFollow { _, instance in numbers.append(instance) }

        registry.add(Caught())
        registry.add(Caught())
        registry.add(Caught())

        #expect(numbers == [1, 2, 3])
    }

    @Test func anObjectCaughtBeforeFollowingKeepsItsNumber() {
        let registry = WeakRegistry<Caught>()
        let first = Caught()
        let second = Caught()
        registry.add(first)
        registry.add(second)

        var numbers = [UInt32]()
        registry.attachAndFollow { _, instance in numbers.append(instance) }

        #expect(numbers.sorted() == [1, 2])
    }

    @Test func theSameObjectArrivingTwiceNotifiesOnce() {
        let registry = WeakRegistry<Caught>()
        var seen = 0
        registry.attachAndFollow { _, _ in seen += 1 }

        let caught = Caught()
        registry.add(caught)
        registry.add(caught)

        #expect(seen == 1, "a chokepoint the app calls twice is one object")
    }

    @Test func aRegistryIsKeyedByTheTypeItTracks() {
        let registries = Registries()
        let first = registries.registry(Caught.self)
        let second = registries.registry(Caught.self)

        #expect(first === second)
    }
}

struct TallyTests {
    @Test func countsAccumulateAndDrainOnTake() {
        let tally = Tally()
        tally.add(.first)
        tally.add(.first, 4)

        #expect(tally.read(.first) == 5)
        #expect(tally.take(.first) == 5)
        #expect(tally.read(.first) == 0, "take drains, so the next interval starts clean")
    }

    @Test func raiseKeepsTheHighWatermark() {
        let tally = Tally()
        tally.raise(.second, to: 10)
        tally.raise(.second, to: 3)
        tally.raise(.second, to: 25)

        #expect(tally.read(.second) == 25)
    }

    @Test func slotsAreIndependent() {
        let tally = Tally()
        tally.add(.first, 1)
        tally.add(.second, 2)
        tally.add(.third, 3)
        tally.add(.fourth, 4)

        #expect([
            tally.read(.first),
            tally.read(.second),
            tally.read(.third),
            tally.read(.fourth),
        ]
            == [1, 2, 3, 4])
    }

    @Test func concurrentIncrementsAreNotLost() async {
        let tally = Tally()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    for _ in 0 ..< 1000 {
                        tally.add(.first)
                    }
                }
            }
        }

        #expect(tally.read(.first) == 8000)
    }
}

struct AtomicStatusTests {
    @Test func startsInactiveAndFlipsBothWays() {
        let status = AtomicStatus()
        #expect(status.isActive == false)

        status.activate()
        #expect(status.isActive)
        #expect(status.current == .active)

        status.deactivate()
        #expect(status.isActive == false)
    }
}

struct ObservationTests {
    @Test func attachDetachIsBalancedAndSeesChanges() {
        let subject = Subject()
        var seen = [Int]()

        let observation = Observation.attach(to: subject, keyPath: "counter") { value in
            if let value = value as? Int {
                seen.append(value)
            }
        }

        subject.counter = 3
        subject.counter = 7
        observation.detach()
        subject.counter = 9

        #expect(seen == [0, 3, 7], "initial, then each change, and nothing after detach")
    }

    @Test func detachingTwiceIsSafe() {
        let subject = Subject()
        let observation = Observation.attach(to: subject, keyPath: "counter") { _ in }
        observation.detach()
        observation.detach()
    }

    /// Removing a KVO observer twice raises, and an ObjC exception cannot be
    /// caught from Swift — the host app goes down with it.
    @Test func detachingFromManyThreadsRemovesTheObserverOnce() {
        let subject = Subject()
        let observation = Observation.attach(to: subject, keyPath: "counter") { _ in }

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            observation.detach()
        }

        #expect(observation.isAttached == false)
    }
}

/// A follower runs on whichever thread called the swizzled method and on the
/// runner queue during activation, so these arrive at once by design.
struct ObservationsTests {
    @Test func attachingFromManyThreadsKeepsEveryObservation() {
        let observations = Observations()
        let subjects = (0 ..< 64).map { _ in Subject() }

        DispatchQueue.concurrentPerform(iterations: subjects.count) { index in
            observations.attach {
                [Observation.attach(to: subjects[index], keyPath: "counter") { _ in }]
            }
        }

        #expect(observations.count == subjects.count)
        observations.detachAll()
        #expect(observations.count == 0)
    }

    @Test func attachingWhileTearingDownLeavesNothingRegistered() {
        let observations = Observations()
        let subjects = (0 ..< 64).map { _ in Subject() }

        DispatchQueue.concurrentPerform(iterations: subjects.count) { index in
            if index == subjects.count / 2 {
                observations.detachAll()
            } else {
                observations.attach {
                    [Observation.attach(to: subjects[index], keyPath: "counter") { _ in }]
                }
            }
        }

        #expect(
            observations.count == 0,
            "every attach that lost the race to teardown was refused"
        )
        observations.detachAll()
    }

    /// A follower snapshotted before the request ended can still be in flight,
    /// and a registration landing after teardown is one nothing removes.
    @Test func attachingAfterTeardownIsRefused() {
        let observations = Observations()
        let subject = Subject()
        observations.detachAll()

        observations.attach {
            [Observation.attach(to: subject, keyPath: "counter") { _ in }]
        }

        #expect(observations.count == 0)
    }

    @Test func anObservationForAReleasedObjectIsDroppedOnTheNextAttach() {
        let observations = Observations()
        let kept = Subject()

        do {
            let transient = Subject()
            observations.attach {
                [Observation.attach(to: transient, keyPath: "counter") { _ in }]
            }
            #expect(observations.count == 1)
        }

        observations.attach {
            [Observation.attach(to: kept, keyPath: "counter") { _ in }]
        }

        #expect(observations.count == 1, "the dead one made way rather than piling up")
        observations.detachAll()
    }
}

struct ClockTests {
    @Test func monotonicTimeDoesNotGoBackwards() {
        let clock = Clock()
        let first = clock.now()
        let second = clock.now()

        #expect(second >= first)
        #expect(second.elapsedMilliseconds(since: first) >= 0)
    }
}

/// An instrument may need an API newer than the SDK's floor. Two declarations
/// carry that: `@available` on the type, which is what stops the compiler
/// accepting the newer API, and `Availability.minIOS`, which is what stops the
/// runtime activating it. This covers the second.
struct AvailabilityTests {
    @Test func anInstrumentNewerThanThisOSIsUnavailable() {
        #expect(Availability(minIOS: 99).isSatisfiedHere == false)
    }

    @Test func aHardwareOnlyInstrumentIsUnavailableOnASimulator() {
        let hardwareOnly = Availability(simulator: false)
        #if targetEnvironment(simulator)
        #expect(hardwareOnly.isSatisfiedHere == false)
        #else
        #expect(hardwareOnly.isSatisfiedHere)
        #endif
    }

    /// Being in the catalog and being runnable here are different questions, so
    /// a registration reports what the instrument declares whether or not this
    /// device satisfies it.
    @Test func aRegistrationReportsWhatTheInstrumentDeclares() {
        #expect(InstrumentID.framePacing.availability.minIOS == 18)
        #expect(InstrumentID.cameraFrameDelivery.availability.simulator == false)
        #expect(InstrumentID.memoryFootprint.availability == Availability())
    }
}

struct AtomicsTests {
    @Test func aCounterSurvivesConcurrentAddsAndDrains() async {
        let tally = Tally(slots: 2)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    for _ in 0 ..< 5000 {
                        tally.add(.first)
                        tally.raise(.second, to: 7)
                    }
                }
            }
        }

        #expect(tally.take(.first) == 40000)
        #expect(tally.read(.second) == 7)
    }

    @Test func aTallyRefusesASlotItNeverAllocated() {
        let tally = Tally(slots: 1)
        #expect(tally.capacity == 1)
        #expect(tally.read(.first) == 0)
    }

    @Test func statusFlipsUnderConcurrentReaders() async {
        let status = AtomicStatus()
        status.activate()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { status.isActive }
            }
            var readers = 0
            for await seen in group where seen {
                readers += 1
            }
            #expect(readers == 8)
        }
        status.deactivate()
        #expect(status.isActive == false)
    }
}
