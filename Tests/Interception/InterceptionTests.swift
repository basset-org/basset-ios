@testable import Basset
import BassetECS
import Foundation
import Testing

/// Swizzling is permanent and process-wide, so each test gets its own class.
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

@objc private class ForeignHookSubject: NSObject {
    nonisolated(unsafe) static var originalRuns = 0
    nonisolated(unsafe) static var foreignRuns = 0

    @objc dynamic func work() {
        Self.originalRuns += 1
    }
}

@objc private class ChainedSubject: Subject {}
@objc private class SharedSubject: Subject {}
@objc private class RestartedSubject: Subject {}
@objc private class ReleasedSubject: Subject {}
@objc private class SiblingSubject: Subject {}
@objc private class DoubledSubject: Subject {}
@objc private class ArgumentSubject: Subject {}
@objc private class TimingSubject: Subject {}
@objc private class ArgumentOwnerSubject: Subject {}
@objc private class SelfTrackSubject: Subject {}
@objc private class UnhookedSubject: Subject {}
@objc private class MismatchSubject: Subject {}
@objc private class MatchedSubject: Subject {}
@objc private class ConflictedSubject: Subject {}

@objc private class Tracked: NSObject {}

/// A two-object setter, the shape `-setSampleBufferDelegate:queue:` has.
@objc private class TwoObjectSubject: NSObject {
    private(set) var ran = 0

    @objc dynamic func set(_ delegate: AnyObject?, queue: AnyObject?) {
        ran += 1
    }
}

/// A sample-buffer delegate as an app writes one: frame callback present, drop absent.
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

@objc private class ForwardingTarget: NSObject {
    var pinged = 0

    @objc dynamic func ping(_: AnyObject?) { pinged += 1 }
}

@objc private class ForwardingProxy: NSObject {
    let target: ForwardingTarget = .init()

    override func forwardingTarget(for selector: Selector) -> Any? {
        target.responds(to: selector) ? target : super.forwardingTarget(for: selector)
    }
}

/// `-URLSession:task:didFinishCollectingMetrics:`, as an app that already collects it.
@objc private class ThreeObjectSubject: NSObject {
    private(set) var ran = 0

    @objc(URLSession:task:didFinishCollectingMetrics:)
    dynamic func urlSession(
        _ session: AnyObject?,
        task: AnyObject?,
        didFinishCollecting metrics: AnyObject?
    ) {
        ran += 1
    }
}

/// The same callback left unwritten, which is what most delegates look like.
@objc private class ThreeObjectSilentSubject: NSObject {}

@objc private class ObjectBufferSubject: NSObject {
    @objc dynamic func captureOutput(
        _ output: AnyObject?,
        didOutputSampleBuffer buffer: AnyObject?,
        fromConnection connection: AnyObject?
    ) {}
}

/// A class-method factory; URLSession is reachable only through one of these.
@objc private class Maker: NSObject {
    @objc dynamic static func make() -> Tracked {
        Tracked()
    }

    @objc dynamic static func make(
        _ first: AnyObject?,
        second: AnyObject?,
        third: AnyObject?
    ) -> Tracked {
        Tracked()
    }

    @objc dynamic func makeOne() -> Tracked {
        Tracked()
    }

    @objc dynamic func doNothing() {}
}

@objc private class TypeFactorySubject: Maker {}
@objc private class InstanceFactorySubject: Maker {}
@objc private class ThreeArgFactorySubject: Maker {}
@objc private class WrongKindSubject: Maker {}

/// A class the `class:`-keyed hooks below reach only by its runtime `AnyClass`, never
/// `Tracked.self`.
/// Swizzling is process-wide and permanent (see the note atop this file), so — same rule as
/// every other subject here — each test below gets its own dedicated pair, never a shared one.
@objc private class RuntimeTrackedSubjectA: NSObject {}
@objc private class RuntimeArgumentOwnerSubjectA: Subject {}
@objc private class RuntimeTrackedSubjectB: NSObject {}
@objc private class RuntimeUntrackedSubjectB: NSObject {}
@objc private class RuntimeArgumentOwnerSubjectB: Subject {}
@objc private class RuntimeTrackedSubjectC: NSObject {}
@objc private class RuntimeArgumentOwnerSubjectC: Subject {}
@objc private class RuntimeTrackedSubjectD: NSObject {}
@objc private class RuntimeSelfTrackSubjectA: Subject {}
@objc private class RuntimeSelfTrackSubjectB: Subject {}
@objc private class RuntimeChangeSubject: TwoObjectSubject {}

/// Emitted only on change — KVO fires on every set even when the state repeats.
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

    /// Two alternating sessions are not repeats — suppressing per entity would drop half.
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
    /// Reading the observer list unguarded could use a buffer a concurrent release already freed.
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

    /// Another SDK's hook on this selector joins the chain rather than being displaced.
    @Test func aHookAnotherSdkInstalledFirstIsStillCalled() throws {
        let selector = #selector(ForeignHookSubject.work)
        let method = try #require(class_getInstanceMethod(ForeignHookSubject.self, selector))
        let original = method_getImplementation(method)
        let foreign: @convention(block) (AnyObject) -> Void = { receiver in
            ForeignHookSubject.foreignRuns += 1
            unsafeBitCast(
                original,
                to: (@convention(c) (AnyObject, Selector) -> Void).self
            )(receiver, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(foreign))

        var seen = 0
        #expect(
            Swizzle().after(ForeignHookSubject.self, selector) { _ in seen += 1 }
                == .installed
        )

        ForeignHookSubject().work()

        #expect(ForeignHookSubject.foreignRuns == 1, "the other SDK's hook still runs")
        #expect(ForeignHookSubject.originalRuns == 1, "and it still reaches the original")
        #expect(seen == 1)
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
        // A second Swizzle instance, to prove the table that matters is process-wide.
        #expect(
            Swizzle()
                .after(SharedSubject.self, #selector(Subject.work)) { _ in second += 1 }
                == .joinedExisting
        )
        SharedSubject().work()

        #expect(first == 1)
        #expect(second == 1)
    }

    /// Without releasing observers first, reactivating left two copies and doubled calls.
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

    /// `void` and `timingVoid` share a signature; only the site table tells them apart.
    @Test func aSecondShapeOnOneSelectorIsRefusedWithoutTrapping() {
        let swizzle = Swizzle()
        var ran = 0

        #expect(
            swizzle
                .after(ConflictedSubject.self, #selector(Subject.work)) { _ in ran += 1 }
                == .installed
        )
        #expect(
            swizzle.timing(ConflictedSubject.self, #selector(Subject.work)) { _, _ in }
                == .shapeConflict(existing: "void", requested: "timingVoid")
        )

        ConflictedSubject().work()
        #expect(ran == 1)
    }

    /// One handle can hold several observers; releasing takes only its own.
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

    /// Defining a method on a proxy shadows its forwarding and drops the app's own handling.
    @Test func aForwardingProxyIsRefusedRatherThanShadowed() {
        let swizzle = Swizzle()
        let selector = #selector(ForwardingTarget.ping(_:))

        #expect(
            swizzle.afterOrDefine(ForwardingProxy.self, selector) { _, _ in }
                == .forwardingClass
        )

        let proxy = ForwardingProxy()
        proxy.perform(selector, with: nil)
        #expect(
            proxy.target.pinged == 1,
            "the proxy's forwarding must still reach its target after the refusal"
        )
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

    /// A wrong-arity hook once made AVFoundation read an unset register and crash.
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
        subject.accept(Tracked())

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
    private static let didFinishCollecting: Selector = .init(
        "URLSession:task:didFinishCollectingMetrics:"
    )

    @Test func aClassFactoryHandsOverWhatItMade() {
        let swizzle = Swizzle()
        var made = [AnyObject]()

        #expect(
            swizzle.afterFactory(
                TypeFactorySubject.self, #selector(Maker.make as () -> Tracked),
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

    /// Dropping the return value would hand the caller whatever was in the register.
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

        let a = Tracked()
        let b = Tracked()
        let returned = ThreeArgFactorySubject.make(a, second: b, third: nil)

        #expect(seen.count == 1)
        #expect(seen.first?.0 === a)
        #expect(seen.first?.1 === b)
        #expect(seen.first?.2 == nil)
        #expect(seen.first?.3 === returned)
    }

    /// A class method lives on the metaclass — reaching through the class finds nothing.
    @Test func aClassMethodIsNotFoundOnTheInstanceSide() {
        let swizzle = Swizzle()

        #expect(
            swizzle.afterFactory(
                WrongKindSubject.self, #selector(Maker.make as () -> Tracked),
                kind: .instance
            ) { _, _ in } == .selectorMissing
        )
    }

    /// A factory shape on a void method would return an object the original never made.
    @Test func aVoidMethodIsRefusedByAFactoryShape() {
        let swizzle = Swizzle()

        #expect(
            swizzle
                .afterFactory(WrongKindSubject.self, #selector(Maker.doNothing)) { _, _ in
                }
                == .returnMismatch(expected: "@", actual: "v")
        )
    }

    /// The other direction of the addOutput: guard — void refuses a returning method.
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
        let delegate = Tracked()
        let queue = Tracked()
        subject.set(delegate, queue: queue)

        #expect(
            subject.ran == 1,
            "the original implementation is chained, never replaced"
        )
        #expect(seen?.0 === delegate)
        #expect(seen?.1 === queue)
    }

    @Test func everyArgumentOfAThreeObjectCallbackReachesTheObserver() {
        let swizzle = Swizzle()
        var seen: (AnyObject?, AnyObject?, AnyObject?)?

        #expect(
            swizzle.after(
                ThreeObjectSubject.self,
                Self.didFinishCollecting,
                takingThreeObjects: ()
            ) { _, first, second, third in
                seen = (first, second, third)
            } == .installed
        )

        let subject = ThreeObjectSubject()
        let session = Tracked()
        let task = Tracked()
        let metrics = Tracked()
        subject.urlSession(session, task: task, didFinishCollecting: metrics)

        #expect(
            subject.ran == 1,
            "the original implementation is chained, never replaced"
        )
        #expect(seen?.0 === session)
        #expect(seen?.1 === task)
        #expect(seen?.2 === metrics)
    }

    /// A delegate that never wrote the callback still delivers it once the method exists.
    @Test func aThreeObjectCallbackTheClassNeverWroteIsDefined() {
        let swizzle = Swizzle()
        var seen = 0

        #expect(
            ThreeObjectSilentSubject().responds(to: Self.didFinishCollecting) == false
        )
        #expect(
            swizzle.afterOrDefine(
                ThreeObjectSilentSubject.self,
                Self.didFinishCollecting,
                takingThreeObjects: ()
            ) { _, _, _, _ in seen += 1 } == .implemented
        )

        let subject = ThreeObjectSilentSubject()
        #expect(
            subject.responds(to: Self.didFinishCollecting),
            "a framework asks before it calls, so defining has to change the answer"
        )
        // perform(_:with:with:) carries two args; the third is register noise.
        let implementation = class_getMethodImplementation(
            ThreeObjectSilentSubject.self,
            Self.didFinishCollecting
        )
        let call = unsafeBitCast(
            implementation,
            to: (@convention(c) (
                AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?
            ) -> Void).self
        )
        call(subject, Self.didFinishCollecting, Tracked(), Tracked(), Tracked())

        #expect(seen == 1)
    }

    /// Three objects and two are different shapes — one site can't carry both thunks.
    @Test func aThreeObjectShapeRefusesATwoObjectSelector() {
        let swizzle = Swizzle()

        #expect(
            swizzle.after(
                TwoObjectSubject.self,
                #selector(TwoObjectSubject.set(_:queue:)),
                takingThreeObjects: ()
            ) { _, _, _, _ in } == .signatureMismatch(expected: 5, actual: 4)
        )
    }

    @Test func aSampleBufferCallbackTheClassWroteIsChained() {
        let swizzle = Swizzle()
        var seen = 0
        var buffer: UnsafeRawPointer?
        var elapsed = [UInt64]()

        #expect(
            swizzle
                .sampleBufferCallback(BufferSubject.self,
                                      Self.didOutput)
                { _, _, got, _, nanoseconds in
                    seen += 1
                    buffer = got
                    elapsed.append(nanoseconds)
                } == .installed
        )

        let subject = BufferSubject()
        let sample = UnsafeRawPointer(bitPattern: 0x1000)
        subject.captureOutput(nil, didOutputSampleBuffer: sample, fromConnection: nil)

        #expect(subject.ran == 1, "the delegate still receives its own frames")
        #expect(seen == 1)
        #expect(buffer == sample, "the buffer reaches the observer without being bridged")
        #expect(elapsed.count == 1, "elapsed covers only the chained call, timed like `timing`")
    }

    /// Lacking the method, a delegate is never called; defining it exposes those frames.
    @Test func aSampleBufferCallbackTheClassLacksIsDefined() {
        let swizzle = Swizzle()
        var seen = 0

        #expect(
            SilentSubject().responds(to: Self.didDrop) == false,
            "nothing answers this selector before the hook"
        )
        #expect(
            swizzle.sampleBufferCallback(SilentSubject.self, Self.didDrop) { _, _, _, _, _ in
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

    /// The buffer slot is what this shape protects from being retained as an object.
    @Test func aSampleBufferShapeRefusesAnObjectWhereTheBufferGoes() {
        let swizzle = Swizzle()

        #expect(
            swizzle.sampleBufferCallback(ObjectBufferSubject.self, Self.didOutput) {
                _, _, _, _, _ in
            } == .argumentKindMismatch(shape: "sampleBufferCallback")
        )
    }
}

struct HookTableTests {
    @Test func aChokepointRegistersWhatPassesThroughIt() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.trackArgument(
            of: Tracked.self,
            at: #selector(Subject.accept(_:)),
            on: ArgumentOwnerSubject.self
        )

        let born = Tracked()
        ArgumentOwnerSubject().accept(born)

        #expect(registries.registry(Tracked.self).all.count == 1)
    }

    @Test func aChokepointCanRegisterTheReceiverItself() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.trackSelf(
            of: SelfTrackSubject.self,
            at: #selector(Subject.work),
            on: SelfTrackSubject.self
        )

        let subject = SelfTrackSubject()
        subject.work()

        #expect(registries.registry(SelfTrackSubject.self).all.count == 1)
    }
}

/// The `class:`-keyed twins Camera/Audio reach a framework class with instead of `of:` —
/// same shapes, but the class only ever arrives as an `AnyClass`, the way `objc_getClass`
/// hands one back, never as a compiled `Tracked.self`.
struct RuntimeClassHookTests {
    @Test func aChokepointRegistersWhatPassesThroughIt() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.trackArgument(
            class: RuntimeTrackedSubjectA.self,
            at: #selector(Subject.accept(_:)),
            on: RuntimeArgumentOwnerSubjectA.self
        )

        let born = RuntimeTrackedSubjectA()
        RuntimeArgumentOwnerSubjectA().accept(born)

        #expect(registries.registry(runtimeClass: RuntimeTrackedSubjectA.self).all.count == 1)
    }

    /// The class check is real, not a pass-through — an argument of the wrong kind is dropped.
    @Test func anArgumentOfTheWrongKindIsNotTracked() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.trackArgument(
            class: RuntimeTrackedSubjectB.self,
            at: #selector(Subject.accept(_:)),
            on: RuntimeArgumentOwnerSubjectB.self
        )

        let wrongKind = RuntimeUntrackedSubjectB()
        RuntimeArgumentOwnerSubjectB().accept(wrongKind)

        #expect(registries.registry(runtimeClass: RuntimeTrackedSubjectB.self).all.isEmpty)
    }

    @Test func aChokepointCanRegisterTheReceiverItself() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.trackSelf(
            class: RuntimeSelfTrackSubjectA.self,
            at: #selector(Subject.work),
            on: RuntimeSelfTrackSubjectA.self
        )

        let subject = RuntimeSelfTrackSubjectA()
        subject.work()

        #expect(registries.registry(runtimeClass: RuntimeSelfTrackSubjectA.self).all.count == 1)
    }

    @Test func aReceiverIsTrackedAtACallTakingAnArgument() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.trackSelf(
            class: RuntimeSelfTrackSubjectB.self,
            atCallTaking: #selector(Subject.accept(_:)),
            on: RuntimeSelfTrackSubjectB.self
        )

        let subject = RuntimeSelfTrackSubjectB()
        subject.accept(Tracked())

        #expect(registries.registry(runtimeClass: RuntimeSelfTrackSubjectB.self).all.count == 1)
    }

    @Test func aChangeIsAnnouncedRatherThanAddedOnce() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        hooks.announceSelf(
            class: RuntimeChangeSubject.self,
            atCallTakingTwo: #selector(TwoObjectSubject.set(_:queue:)),
            on: RuntimeChangeSubject.self
        )

        var seen = 0
        registries.registry(runtimeClass: RuntimeChangeSubject.self)
            .attachAndFollow { _, _ in seen += 1 }

        let subject = RuntimeChangeSubject()
        subject.set(Tracked(), queue: Tracked())
        subject.set(Tracked(), queue: Tracked())

        #expect(seen == 2, "announce re-notifies on every call, unlike trackSelf/trackArgument")
    }

    @Test func followReachesInstancesAlreadyTrackedAndOnesTrackedLater() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)
        let status = AtomicStatus()
        status.activate()
        let context = Context(
            instrumentName: "test",
            defaultEntity: .appLifecycle,
            status: status,
            swizzle: hooks.swizzle,
            registries: registries,
            timerQueue: DispatchQueue(label: "test.runtimeClass.follow"),
            sink: { _ in }
        )

        hooks.trackArgument(
            class: RuntimeTrackedSubjectC.self,
            at: #selector(Subject.accept(_:)),
            on: RuntimeArgumentOwnerSubjectC.self
        )
        let before = RuntimeTrackedSubjectC()
        RuntimeArgumentOwnerSubjectC().accept(before)

        var attached = [AnyObject]()
        context.follow(class: RuntimeTrackedSubjectC.self) { object, _ in attached.append(object) }
        #expect(attached.count == 1, "what was already tracked")

        RuntimeArgumentOwnerSubjectC().accept(RuntimeTrackedSubjectC())
        #expect(attached.count == 2, "and what arrives next")
    }

    @Test func aRuntimeRegistryIsKeyedByTheClassItTracks() {
        let registries = Registries()
        let first = registries.registry(runtimeClass: RuntimeTrackedSubjectD.self)
        let second = registries.registry(runtimeClass: RuntimeTrackedSubjectD.self)

        #expect(first === second)
    }
}

struct WeakRegistryTests {
    @Test func aDeadEntryVanishes() {
        let registry = WeakRegistry<Tracked>()
        autoreleasepool {
            let transient = Tracked()
            registry.add(transient)
            #expect(registry.count == 1)
        }
        #expect(registry.count == 0, "basset never retains an app object")
    }

    /// `add` stays silent on a known object — announce is what re-notifies followers.
    @Test func announcingAKnownObjectTellsTheFollowersAgain() {
        let registry = WeakRegistry<Tracked>()
        let tracked = Tracked()
        registry.add(tracked)

        var attached = [Tracked]()
        registry.attachAndFollow { object, _ in attached.append(object) }
        #expect(attached.count == 1)

        registry.add(tracked)
        #expect(attached.count == 1, "adding what is already held stays silent")

        registry.announce(tracked)
        #expect(attached.count == 2, "announcing it does not")
        #expect(attached.last === tracked)
    }

    /// Announcing an unknown object is the same as it arriving — either order works.
    @Test func announcingAnUnknownObjectAddsIt() {
        let registry = WeakRegistry<Tracked>()
        var attached = [Tracked]()
        registry.attachAndFollow { object, _ in attached.append(object) }

        let tracked = Tracked()
        registry.announce(tracked)

        #expect(registry.count == 1)
        #expect(attached.count == 1)
    }

    /// The number outlives the address — a reused address must not inherit an old sample.
    @Test func theInstanceNumberIsNotReusedWhenAnAddressIs() {
        let registry = WeakRegistry<Tracked>()
        var first: UInt32?
        autoreleasepool {
            let transient = Tracked()
            registry.add(transient)
            first = registry.tracked.first?.instance
        }

        let replacement = Tracked()
        registry.add(replacement)

        #expect(first != nil)
        #expect(registry.tracked.first?.instance != first)
    }

    @Test func addingTheSameObjectTwiceKeepsOneEntry() {
        let registry = WeakRegistry<Tracked>()
        let tracked = Tracked()
        registry.add(tracked)
        registry.add(tracked)

        #expect(registry.count == 1)
    }

    /// A registry walked only once at activation misses every object built afterward.
    @Test func followingReachesObjectsBornAfterActivation() {
        let registry = WeakRegistry<Tracked>()
        let before = Tracked()
        registry.add(before)

        var attached = [Tracked]()
        registry.attachAndFollow { tracked, _ in attached.append(tracked) }
        #expect(attached.count == 1, "what was already tracked")

        let after = Tracked()
        registry.add(after)

        #expect(attached.count == 2, "and what arrives next")
        #expect(attached.last === after)
    }

    @Test func oneInstrumentUnfollowingLeavesItsSiblingsAttached() {
        let registry = WeakRegistry<Tracked>()
        var first = 0
        var second = 0

        let token = registry.attachAndFollow { _, _ in first += 1 }
        registry.attachAndFollow { _, _ in second += 1 }

        registry.add(Tracked())
        registry.stopFollowing(token)
        registry.add(Tracked())

        #expect(first == 1, "stopped after the first arrival")
        #expect(second == 2, "the sibling still hears about both")
    }

    /// The registry numbers what it catches, so instruments get identity for free.
    @Test func everyTrackedObjectGetsItsOwnNumber() {
        let registry = WeakRegistry<Tracked>()
        var numbers = [UInt32]()
        registry.attachAndFollow { _, instance in numbers.append(instance) }

        registry.add(Tracked())
        registry.add(Tracked())
        registry.add(Tracked())

        #expect(numbers == [1, 2, 3])
    }

    @Test func anObjectTrackedBeforeFollowingKeepsItsNumber() {
        let registry = WeakRegistry<Tracked>()
        let first = Tracked()
        let second = Tracked()
        registry.add(first)
        registry.add(second)

        var numbers = [UInt32]()
        registry.attachAndFollow { _, instance in numbers.append(instance) }

        #expect(numbers.sorted() == [1, 2])
    }

    @Test func theSameObjectArrivingTwiceNotifiesOnce() {
        let registry = WeakRegistry<Tracked>()
        var seen = 0
        registry.attachAndFollow { _, _ in seen += 1 }

        let tracked = Tracked()
        registry.add(tracked)
        registry.add(tracked)

        #expect(seen == 1, "a chokepoint the app calls twice is one object")
    }

    @Test func aRegistryIsKeyedByTheTypeItTracks() {
        let registries = Registries()
        let first = registries.registry(Tracked.self)
        let second = registries.registry(Tracked.self)

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

    /// Removing a KVO observer twice raises — uncatchable, so the host app dies.
    @Test func detachingFromManyThreadsRemovesTheObserverOnce() {
        let subject = Subject()
        let observation = Observation.attach(to: subject, keyPath: "counter") { _ in }

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            observation.detach()
        }

        #expect(observation.isAttached == false)
    }
}

/// A follower runs on the swizzled thread and the runner queue — overlap is by design.
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

    /// A late registration lands after teardown, so nothing is left to remove it.
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

/// `@available` gates the compiler; `Availability.minIOS` gates the runtime, tested here.
struct AvailabilityTests {
    @Test func anInstrumentNewerThanThisOSIsUnavailable() {
        #if os(iOS)
        #expect(Availability(minIOS: 99).isSatisfiedHere == false)
        #else
        #expect(
            Availability(minIOS: 99).isSatisfiedHere,
            "the floor is an iOS floor, and a Mac's version does not answer it"
        )
        #endif
    }

    @Test func aHardwareOnlyInstrumentIsUnavailableOnASimulator() {
        let hardwareOnly = Availability(simulator: false)
        #if targetEnvironment(simulator)
        #expect(hardwareOnly.isSatisfiedHere == false)
        #else
        #expect(hardwareOnly.isSatisfiedHere)
        #endif
    }

    /// Catalog membership and runnability are different — this reports what's declared.
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

/// One selector on both sides of one class name — a name-keyed site table merges them.
@objc private class BothSidesSubject: NSObject {
    @objc dynamic class func fetch() -> Tracked {
        Tracked()
    }

    @objc dynamic func fetch() -> Tracked {
        Tracked()
    }
}

/// `setDelegate:queue:` as CXProvider declares it — the delegate is the first of two arguments.
@objc private class DelegateQueueSubject: NSObject {
    @objc dynamic func setDelegate(_ delegate: AnyObject?, queue: AnyObject?) {}
}

@objc private class RefusedDelegateQueueSubject: NSObject {
    @objc dynamic func setDelegate(_ delegate: AnyObject?, queue: AnyObject?) {}
}

@objc private class KVOCatchSubject: NSObject {
    @objc dynamic func adopt(_ delegate: AnyObject?) {}
}

struct SiteIdentityTests {
    @Test func aClassMethodAndAnInstanceMethodWithOneSelectorGetTheirOwnSites() {
        let swizzle = Swizzle()
        let selector = Selector(("fetch"))
        nonisolated(unsafe) var classSide = 0
        nonisolated(unsafe) var instanceSide = 0

        #expect(swizzle.afterFactory(BothSidesSubject.self, selector, kind: .type) { _, _ in
            classSide += 1
        } == .installed)
        #expect(swizzle.afterFactory(BothSidesSubject.self, selector) { _, _ in
            instanceSide += 1
        } == .installed)

        _ = BothSidesSubject.fetch()
        #expect(classSide == 1)
        #expect(instanceSide == 0)

        _ = BothSidesSubject().fetch()
        #expect(classSide == 1)
        #expect(instanceSide == 1)
        swizzle.releaseObservers()
    }
}

extension HookTableTests {
    @Test func aTwoArgumentDelegateSetterStillYieldsItsDelegateClass() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)

        let outcome = hooks.trackDelegateClass(
            at: Selector(("setDelegate:queue:")),
            on: DelegateQueueSubject.self,
            takingTwoObjects: ()
        )
        #expect(outcome == .installed)

        DelegateQueueSubject().setDelegate(Tracked(), queue: nil)

        let recorded = registries.delegates(ObjectIdentifier(DelegateQueueSubject.self)).all
        #expect(recorded.count == 1)
        #expect(recorded.first === Tracked.self)
    }

    /// The shape guard that made `CXProvider`'s delegate silently unwatchable.
    @Test func aOneObjectCatchOnATwoArgumentSetterIsRefusedNotTrapped() {
        let hooks = HookTable(swizzle: Swizzle(), registries: Registries())

        let outcome = hooks.trackDelegateClass(
            at: Selector(("setDelegate:queue:")),
            on: RefusedDelegateQueueSubject.self
        )

        #expect(outcome == .signatureMismatch(expected: 3, actual: 4))
    }

    /// KVO's dynamic subclass melts away with its observer; hooks must land on the real class.
    @Test func aKVOObservedDelegateIsRecordedByItsPublicClass() {
        let registries = Registries()
        let hooks = HookTable(swizzle: Swizzle(), registries: registries)
        _ = hooks.trackDelegateClass(
            at: #selector(KVOCatchSubject.adopt(_:)),
            on: KVOCatchSubject.self
        )

        let delegate = Subject()
        let observation = Observation.attach(to: delegate, keyPath: "counter") { _ in }
        KVOCatchSubject().adopt(delegate)
        observation.detach()

        let recorded = registries.delegates(ObjectIdentifier(KVOCatchSubject.self)).all
        #expect(recorded.count == 1)
        #expect(recorded.first === Subject.self)
    }
}

extension ObservationTests {
    /// KVO holds its observer unretained; while attached the observation holds itself.
    @Test func anObservationOutlivesItsLastStrongReferenceWhileAttached() {
        let subject = Subject()
        nonisolated(unsafe) var seen = 0
        weak var watched: Observation?

        autoreleasepool {
            let observation = Observation.attach(
                to: subject,
                keyPath: "counter",
                initial: false
            ) { _ in
                seen += 1
            }
            watched = observation
        }

        subject.counter = 3
        #expect(seen == 1, "delivery lands on a live observer, not freed memory")

        watched?.detach()
        subject.counter = 5
        #expect(seen == 1)
    }
}
