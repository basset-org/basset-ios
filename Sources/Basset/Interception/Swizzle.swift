import Foundation
import ObjectiveC

public enum SwizzleOutcome: Equatable, Sendable {
    case installed
    case joinedExisting
    /// Added, not wrapped — no method existed; frameworks check respondsToSelector first.
    case implemented
    case classMissing
    case selectorMissing
    /// The class forwards this selector rather than implementing it; defining a method
    /// would shadow that forwarding and drop the app's own handling of the callback.
    case forwardingClass
    /// Shape doesn't fit the selector — chaining through it would read a wrong register.
    case signatureMismatch(expected: Int, actual: Int)
    /// Right count, wrong kind — a BOOL read as an object reads true as a pointer.
    case argumentKindMismatch(shape: String)
    /// Shape and selector disagree on the return — passing it through hands back garbage.
    case returnMismatch(expected: String, actual: String)
    /// Already hooked under another shape — matching ObjC signatures still can't merge.
    case shapeConflict(existing: String, requested: String)
}

/// What a selector must look like to chain it — data, not a switch per shape added.
struct HookShape: Equatable {
    static let void: HookShape = .init(
        name: "void",
        arguments: 2,
        returns: "v",
        firstArgument: nil
    )
    static let voidBool: HookShape = .init(
        name: "voidBool",
        arguments: 3,
        returns: "v",
        firstArgument: "B"
    )
    static let voidObject: HookShape = .init(
        name: "voidObject", arguments: 3, returns: "v", firstArgument: "@"
    )
    static let voidTwoObjects: HookShape = .init(
        name: "voidTwoObjects", arguments: 4, returns: "v", firstArgument: "@"
    )
    /// `-URLSession:task:didFinishCollecting:` and its completion counterpart.
    static let voidThreeObjects: HookShape = .init(
        name: "voidThreeObjects", arguments: 5, returns: "v", firstArgument: "@"
    )
    /// `-sendAction:to:forEvent:` — its first argument is a `SEL`, not an object.
    static let sendActionCallback: HookShape = .init(
        name: "sendActionCallback", arguments: 5, returns: "v", firstArgument: ":"
    )
    /// `-setState:` — an `NS_ENUM(NSInteger, ...)` argument, encoded `q` on the 64-bit-only
    /// runtime this package's iOS 17 floor guarantees.
    static let voidInteger: HookShape = .init(
        name: "voidInteger", arguments: 3, returns: "v", firstArgument: "q"
    )
    static let timingVoid: HookShape = .init(
        name: "timingVoid", arguments: 2, returns: "v", firstArgument: nil
    )
    /// `-[CIContext render:toMTLTexture:commandBuffer:bounds:colorSpace:]` — three objects,
    /// a `CGRect` by value, then a `CGColorSpaceRef` which is a pointer, not an object.
    static let textureRenderCallback: HookShape = .init(
        name: "textureRenderCallback",
        arguments: 7,
        returns: "v",
        firstArgument: "@",
        pointerArgument: 6,
        argumentEncodings: [3: "@", 4: "@", 5: "{CGRect"]
    )

    /// `-captureOutput:didOutputSampleBuffer:fromConnection:` and its drop counterpart.
    static let sampleBufferCallback: HookShape = .init(
        name: "sampleBufferCallback",
        arguments: 5,
        returns: "v",
        firstArgument: "@",
        pointerArgument: 3
    )

    /// `-collectionView:cellForItemAtIndexPath:` — two objects in, one out, timed around the call.
    static let timedFactoryTwoObjects: HookShape = .init(
        name: "timedFactory2", arguments: 4, returns: "@", firstArgument: "@"
    )

    /// An init consumes self and may return nil having released it: observers see only the result.
    static let initializerTwoObjects: HookShape = .init(
        name: "initializer2", arguments: 4, returns: "@", firstArgument: "@"
    )

    /// `-[CIImage initWithCVPixelBuffer:options:]` and its CGImage twin: a CoreFoundation
    /// pointer first, an options dictionary second, an object out.
    static let initializerPointerAndObject: HookShape = .init(
        name: "initializerPointerAndObject",
        arguments: 4,
        returns: "@",
        firstArgument: nil,
        pointerArgument: 2,
        argumentEncodings: [3: "@"]
    )

    let name: String
    /// Including self and _cmd, the way the ObjC runtime counts.
    let arguments: Int
    /// The ObjC encoding the method must return: "v" for void, "@" for an object.
    let returns: String
    /// First argument's encoding — "B" and "@" share a slot but aren't interchangeable.
    let firstArgument: String?
    /// Raw-pointer argument, not an object — CMSampleBufferRef would be wrongly retained.
    var pointerArgument: Int?
    /// Every other argument that has to be what the thunk reads it as. Without these a
    /// selector of the same arity installs and the thunk reads a wrong register as an object.
    var argumentEncodings: [Int: String] = [:]

    static func factory(objects count: Int) -> HookShape {
        HookShape(
            name: "factory\(count)",
            arguments: 2 + count,
            returns: "@",
            firstArgument: count == 0 ? nil : "@"
        )
    }
}

/// Type or instance — a class method lives on the metaclass, not the type itself.
public enum MethodKind: Equatable, Sendable {
    case instance
    case type

    func hooked(_ target: AnyClass) -> AnyClass? {
        switch self {
        case .instance: target
        case .type: object_getClass(target)
        }
    }
}

/// Which handle registered — ids never repeat, so a released one can't be confused later.
struct HookOwner: Hashable, Sendable {
    let rawValue: UInt64
}

private protocol AnyHookSite: AnyObject {
    var shape: HookShape { get }
    func release(_ owner: HookOwner)
}

private final class HookSite<Body>: AnyHookSite {
    /// One lock per hooked call: the IMP to chain and the observers to run, read together.
    struct Live {
        let chained: IMP?
        let observers: [Body]
    }

    private struct State {
        var chained: IMP?
        var owners: [HookOwner] = []
        var bodies: [Body] = []
    }

    let shape: HookShape
    let selector: Selector

    private let guarded: Mutex<State>

    init(shape: HookShape, selector: Selector) {
        self.shape = shape
        self.selector = selector
        guarded = .init(State())
    }

    /// A copy under the lock, walked outside it — observers are app code, run unlocked.
    func live() -> Live {
        guarded.withLock { Live(chained: $0.chained, observers: $0.bodies) }
    }

    func add(_ owner: HookOwner, _ body: Body) {
        guarded.withLock {
            $0.owners.append(owner)
            $0.bodies.append(body)
        }
    }

    func release(_ owner: HookOwner) {
        guarded.withLock { state in
            for index in state.owners.indices.reversed() where state.owners[index] == owner {
                state.owners.remove(at: index)
                state.bodies.remove(at: index)
            }
        }
    }

    /// Swap and record happen together — a thunk mid-call must not chain a stale IMP.
    func replacing(_ swap: () -> IMP?) {
        guarded.withLock { $0.chained = swap() }
    }

    func callChained(_ chained: IMP?, _ receiver: AnyObject) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector) -> Void).self
        )
        original(receiver, selector)
    }

    func callChained(_ chained: IMP?, _ receiver: AnyObject, _ flag: Bool) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self
        )
        original(receiver, selector, flag)
    }

    func callChained(_ chained: IMP?, _ receiver: AnyObject, _ argument: AnyObject?) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self
        )
        original(receiver, selector, argument)
    }

    func callChained(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ first: AnyObject?,
        _ second: AnyObject?
    ) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void)
                .self
        )
        original(receiver, selector, first, second)
    }

    func callChained(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ first: AnyObject?,
        _ second: AnyObject?,
        _ third: AnyObject?
    ) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (
                AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?
            ) -> Void).self
        )
        original(receiver, selector, first, second, third)
    }

    func callChained(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ action: Selector,
        _ target: AnyObject?,
        _ event: AnyObject?
    ) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (
                AnyObject, Selector, Selector, AnyObject?, AnyObject?
            ) -> Void).self
        )
        original(receiver, selector, action, target, event)
    }

    func callChained(_ chained: IMP?, _ receiver: AnyObject, _ integer: Int) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, Int) -> Void).self
        )
        original(receiver, selector, integer)
    }

    func callChained(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ output: AnyObject?,
        _ buffer: UnsafeRawPointer?,
        _ connection: AnyObject?
    ) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (
                AnyObject, Selector, AnyObject?, UnsafeRawPointer?, AnyObject?
            ) -> Void).self
        )
        original(receiver, selector, output, buffer, connection)
    }

    /// Drops nothing — the app must get back exactly what the original method produced.
    func callChained(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ first: AnyObject?,
        _ second: AnyObject?,
        _ third: AnyObject?,
        _ rect: CGRect,
        _ pointer: UnsafeRawPointer?
    ) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (
                AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, CGRect,
                UnsafeRawPointer?
            ) -> Void).self
        )
        original(receiver, selector, first, second, third, rect, pointer)
    }

    func callChainedReturning(_ chained: IMP?, _ receiver: AnyObject) -> AnyObject? {
        guard let chained else {
            return nil
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self
        )
        return original(receiver, selector)
    }

    func callChainedReturning(_ chained: IMP?, _ receiver: AnyObject,
                              _ first: AnyObject?) -> AnyObject?
    {
        guard let chained else {
            return nil
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?).self
        )
        return original(receiver, selector, first)
    }

    func callChainedReturning(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ first: AnyObject?,
        _ second: AnyObject?
    ) -> AnyObject? {
        guard let chained else {
            return nil
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, AnyObject?, AnyObject?)
                -> AnyObject?).self
        )
        return original(receiver, selector, first, second)
    }

    func callChainedReturning(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ pointer: UnsafeRawPointer?,
        _ object: AnyObject?
    ) -> AnyObject? {
        guard let chained else {
            return nil
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, UnsafeRawPointer?, AnyObject?)
                -> AnyObject?).self
        )
        return original(receiver, selector, pointer, object)
    }

    func callChainedReturning(
        _ chained: IMP?,
        _ receiver: AnyObject,
        _ first: AnyObject?,
        _ second: AnyObject?,
        _ third: AnyObject?
    ) -> AnyObject? {
        guard let chained else {
            return nil
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (
                AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?
            ) -> AnyObject?).self
        )
        return original(receiver, selector, first, second, third)
    }
}

public final class Swizzle: @unchecked Sendable {
    /// Told on the way in and on the way out, so a watcher can arm before the call and read
    /// what it made, and how long it took, after. The return passes through unsubstituted.
    public struct TimedFactoryObserver {
        public let entering: (AnyObject, AnyObject?, AnyObject?) -> Void
        public let leaving: (AnyObject, AnyObject?, AnyObject?, AnyObject?, UInt64) -> Void

        public init(
            entering: @escaping (AnyObject, AnyObject?, AnyObject?) -> Void,
            leaving: @escaping (AnyObject, AnyObject?, AnyObject?, AnyObject?, UInt64) -> Void
        ) {
            self.entering = entering
            self.leaving = leaving
        }
    }

    /// Entering runs before the chained call; elapsed covers only that call.
    public struct SampleBufferObserver {
        public let entering: (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?) -> Void
        public let leaving: (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?, UInt64) -> Void

        public init(
            entering: @escaping (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?) -> Void,
            leaving: @escaping (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?, UInt64)
                -> Void
        ) {
            self.entering = entering
            self.leaving = leaving
        }
    }

    /// Keyed on class identity: a metaclass and its class share a name, as can two images.
    private struct SiteKey: Hashable {
        let hooked: ObjectIdentifier
        let selector: Selector
    }

    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var sites: [SiteKey: any AnyHookSite] = [:]
    private nonisolated(unsafe) static var ownersHandedOut: UInt64 = 0

    /// v@:@^v@ — written out; no existing method has this signature to copy it from.
    private static let sampleBufferEncoding = "v@:@^v@"

    /// One handle on a process-wide table — releasing it leaves other owners intact.
    let owner: HookOwner

    public init() {
        Self.lock.lock()
        Self.ownersHandedOut += 1
        owner = HookOwner(rawValue: Self.ownersHandedOut)
        Self.lock.unlock()
    }

    private static func returnEncoding(_ method: Method) -> String {
        let raw = method_copyReturnType(method)
        defer { free(raw) }
        return String(cString: raw)
    }

    private static func argumentEncoding(_ method: Method, at index: Int) -> String? {
        guard let raw = method_copyArgumentType(method, UInt32(index)) else {
            return nil
        }

        defer { free(raw) }
        return String(cString: raw)
    }

    private static func key(_ hooked: AnyClass, _ selector: Selector) -> SiteKey {
        SiteKey(hooked: ObjectIdentifier(hooked), selector: selector)
    }

    /// A class that overrides a forwarding hook off NSObject's routes unknown selectors to
    /// another object — the shape an Rx delegate proxy or an NSProxy stand-in takes. A full
    /// forwardInvocation: proxy overrides methodSignatureForSelector: as well, so checking
    /// that one would only refuse classes that customize it for unrelated reasons.
    private static func forwardsMessages(_ hooked: AnyClass) -> Bool {
        let hooks = ["forwardInvocation:", "forwardingTargetForSelector:"]
        return hooks.contains { overridesNSObject(hooked, NSSelectorFromString($0)) }
    }

    private static func overridesNSObject(_ hooked: AnyClass, _ selector: Selector) -> Bool {
        let onClass = class_getMethodImplementation(hooked, selector)
            .map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
        let onNSObject = class_getMethodImplementation(NSObject.self, selector)
            .map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
        return onClass != onNSObject
    }

    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .void, observer: observer) { site in
            let block: @convention(block) (AnyObject) -> Void = { receiver in
                let live = site.live()
                site.callChained(live.chained, receiver)
                for observe in live.observers {
                    observe(receiver)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject, Bool) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .voidBool, observer: observer) { site in
            let block: @convention(block) (AnyObject, Bool) -> Void = { receiver, flag in
                let live = site.live()
                site.callChained(live.chained, receiver, flag)
                for observe in live.observers {
                    observe(receiver, flag)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .voidObject, observer: observer) { site in
            let block: @convention(block) (AnyObject, AnyObject?)
                -> Void = { receiver, argument in
                    let live = site.live()
                    site.callChained(live.chained, receiver, argument)
                    for observe in live.observers {
                        observe(
                            receiver,
                            argument
                        )
                    }
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// `-setSampleBufferDelegate:queue:` — names who receives every frame an output makes.
    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        takingTwoObjects: Void,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .voidTwoObjects, observer: observer) { site in
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = {
                receiver, first, second in
                let live = site.live()
                site.callChained(live.chained, receiver, first, second)
                for observe in live.observers {
                    observe(
                        receiver, first, second
                    )
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// `-URLSession:task:didFinishCollecting:` — where a request's phase timestamps land.
    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        takingThreeObjects: Void,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .voidThreeObjects, observer: observer) { site in
            let block: @convention(block) (
                AnyObject, AnyObject?, AnyObject?, AnyObject?
            ) -> Void = { receiver, first, second, third in
                let live = site.live()
                site.callChained(live.chained, receiver, first, second, third)
                for observe in live.observers {
                    observe(receiver, first, second, third)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// `-sendAction:to:forEvent:` — which control fired and where the action was sent.
    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        takingSelectorAndTwoObjects: Void,
        _ observer: @escaping (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .sendActionCallback, observer: observer) { site in
            let block: @convention(block) (
                AnyObject, Selector, AnyObject?, AnyObject?
            ) -> Void = { receiver, action, target, event in
                let live = site.live()
                site.callChained(live.chained, receiver, action, target, event)
                for observe in live.observers {
                    observe(receiver, action, target, event)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// `-setState:` — not declared in `UIGestureRecognizer`'s public header.
    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        takingInteger: Void,
        _ observer: @escaping (AnyObject, Int) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .voidInteger, observer: observer) { site in
            let block: @convention(block) (AnyObject, Int) -> Void = { receiver, value in
                let live = site.live()
                site.callChained(live.chained, receiver, value)
                for observe in live.observers {
                    observe(receiver, value)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Defines a missing callback only if void, handler-free — else it can crash the app.
    public func afterOrDefine(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target,
            selector,
            shape: .voidObject,
            addWhenAbsent: "v@:@",
            observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, AnyObject?)
                -> Void = { receiver, argument in
                    let live = site.live()
                    site.callChained(live.chained, receiver, argument)
                    for observe in live.observers {
                        observe(
                            receiver,
                            argument
                        )
                    }
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// Two-object shape of `afterOrDefine`, under the same rule.
    public func afterOrDefine(
        _ target: AnyClass?,
        _ selector: Selector,
        takingTwoObjects _: Void,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target,
            selector,
            shape: .voidTwoObjects,
            addWhenAbsent: "v@:@@",
            observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = {
                receiver, first, second in
                let live = site.live()
                site.callChained(live.chained, receiver, first, second)
                for observe in live.observers {
                    observe(
                        receiver, first, second
                    )
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Three-object shape of `afterOrDefine` — costs building a URLSessionTaskMetrics.
    public func afterOrDefine(
        _ target: AnyClass?,
        _ selector: Selector,
        takingThreeObjects _: Void,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target,
            selector,
            shape: .voidThreeObjects,
            addWhenAbsent: "v@:@@@",
            observer: observer
        ) { site in
            let block: @convention(block) (
                AnyObject, AnyObject?, AnyObject?, AnyObject?
            ) -> Void = { receiver, first, second, third in
                let live = site.live()
                site.callChained(live.chained, receiver, first, second, third)
                for observe in live.observers {
                    observe(receiver, first, second, third)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Wraps where the delegate exists, defines where not — the buffer stays unbridged.
    public func sampleBufferCallback(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?, UInt64)
            -> Void
    ) -> SwizzleOutcome {
        sampleBufferCallback(
            target,
            selector,
            observing: SampleBufferObserver(entering: { _, _, _, _ in }, leaving: observer)
        )
    }

    public func sampleBufferCallback(
        _ target: AnyClass?,
        _ selector: Selector,
        observing observer: SampleBufferObserver
    ) -> SwizzleOutcome {
        install(
            target,
            selector,
            shape: .sampleBufferCallback,
            addWhenAbsent: Self.sampleBufferEncoding,
            observer: observer
        ) { site in
            let block: @convention(block) (
                AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?
            ) -> Void = { receiver, output, buffer, connection in
                let live = site.live()
                guard !live.observers.isEmpty else {
                    site.callChained(live.chained, receiver, output, buffer, connection)
                    return
                }

                for observe in live.observers {
                    observe.entering(receiver, output, buffer, connection)
                }
                var started = timespec()
                clock_gettime(CLOCK_UPTIME_RAW, &started)
                site.callChained(live.chained, receiver, output, buffer, connection)
                var finished = timespec()
                clock_gettime(CLOCK_UPTIME_RAW, &finished)

                let startedAt = UInt64(started.tv_sec) * 1000000000 + UInt64(started.tv_nsec)
                let finishedAt = UInt64(finished.tv_sec) * 1000000000 + UInt64(finished.tv_nsec)
                let elapsed = finishedAt > startedAt ? finishedAt - startedAt : 0
                for observe in live.observers {
                    observe.leaving(receiver, output, buffer, connection, elapsed)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    public func timing(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject, UInt64) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .timingVoid, observer: observer) { site in
            let block: @convention(block) (AnyObject) -> Void = { receiver in
                let live = site.live()
                guard !live.observers.isEmpty else {
                    site.callChained(live.chained, receiver)
                    return
                }

                var started = timespec()
                clock_gettime(CLOCK_UPTIME_RAW, &started)
                site.callChained(live.chained, receiver)
                var finished = timespec()
                clock_gettime(CLOCK_UPTIME_RAW, &finished)

                let startedAt = UInt64(started.tv_sec) * 1000000000 +
                    UInt64(started.tv_nsec)
                let finishedAt = UInt64(finished.tv_sec) * 1000000000 +
                    UInt64(finished.tv_nsec)
                let elapsed = finishedAt > startedAt ? finishedAt - startedAt : 0
                for observe in live.observers {
                    observe(receiver, elapsed)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    public func timingFactory(
        _ target: AnyClass?,
        _ selector: Selector,
        takingTwoObjects: Void,
        _ observer: TimedFactoryObserver
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .timedFactoryTwoObjects, observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?)
                -> AnyObject? = {
                    receiver, first, second in
                    let live = site.live()
                    guard !live.observers.isEmpty else {
                        return site.callChainedReturning(live.chained, receiver, first, second)
                    }

                    for observe in live.observers {
                        observe.entering(receiver, first, second)
                    }
                    var started = timespec()
                    clock_gettime(CLOCK_UPTIME_RAW, &started)
                    let made = site.callChainedReturning(live.chained, receiver, first, second)
                    var finished = timespec()
                    clock_gettime(CLOCK_UPTIME_RAW, &finished)

                    let startedAt = UInt64(started.tv_sec) * 1000000000 +
                        UInt64(started.tv_nsec)
                    let finishedAt = UInt64(finished.tv_sec) * 1000000000 +
                        UInt64(finished.tv_nsec)
                    let elapsed = finishedAt > startedAt ? finishedAt - startedAt : 0
                    for observe in live.observers {
                        observe.leaving(receiver, first, second, made, elapsed)
                    }
                    return made
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// Hooks a factory to see what it made — the return passes through unsubstituted.
    public func afterFactory(
        _ target: AnyClass?,
        _ selector: Selector,
        kind: MethodKind = .instance,
        _ observer: @escaping (AnyObject, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .factory(objects: 0), kind: kind, observer: observer
        ) { site in
            let block: @convention(block) (AnyObject) -> AnyObject? = { receiver in
                let live = site.live()
                let made = site.callChainedReturning(live.chained, receiver)
                for observe in live.observers {
                    observe(receiver, made)
                }
                return made
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Three objects, a rect by value, and a pointer — the shape a Core Image render takes.
    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        takingThreeObjectsRectAndPointer: Void,
        _ observer: @escaping (AnyObject) -> Void
    ) -> SwizzleOutcome {
        install(
            target,
            selector,
            shape: .textureRenderCallback,
            observer: observer
        ) { site in
            let block: @convention(block) (
                AnyObject, AnyObject?, AnyObject?, AnyObject?, CGRect, UnsafeRawPointer?
            ) -> Void = { receiver, first, second, third, rect, pointer in
                let live = site.live()
                site.callChained(live.chained, receiver, first, second, third, rect, pointer)
                for observe in live.observers {
                    observe(receiver)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// One object — `-dataTaskWithRequest:` and siblings, how nearly every task is made.
    public func afterFactory(
        _ target: AnyClass?,
        _ selector: Selector,
        takingOneObject: Void,
        kind: MethodKind = .instance,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .factory(objects: 1), kind: kind, observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = {
                receiver, first in
                let live = site.live()
                let made = site.callChainedReturning(live.chained, receiver, first)
                for observe in live.observers {
                    observe(
                        receiver, first, made
                    )
                }
                return made
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Two — completion-handler task factories, whose second object is the block.
    public func afterFactory(
        _ target: AnyClass?,
        _ selector: Selector,
        takingTwoObjects: Void,
        kind: MethodKind = .instance,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .factory(objects: 2), kind: kind, observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?)
                -> AnyObject? = {
                    receiver, first, second in
                    let live = site.live()
                    let made = site.callChainedReturning(live.chained, receiver, first, second)
                    for observe in live.observers {
                        observe(receiver, first, second, made)
                    }
                    return made
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// An `init…:…:` taking two objects; the observer sees what was made and nothing else.
    public func afterInitializer(
        _ target: AnyClass?,
        _ selector: Selector,
        takingTwoObjects: Void,
        _ observer: @escaping (AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .initializerTwoObjects, observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?)
                -> AnyObject? = {
                    receiver, first, second in
                    let live = site.live()
                    let made = site.callChainedReturning(live.chained, receiver, first, second)
                    for observe in live.observers {
                        observe(made)
                    }
                    return made
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// An `init…:…:` taking a CoreFoundation pointer and an object — the pointer is passed
    /// through untouched, never retained, and the observer sees only what was made.
    public func afterInitializer(
        _ target: AnyClass?,
        _ selector: Selector,
        takingPointerAndObject: Void,
        _ observer: @escaping (AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .initializerPointerAndObject, observer: observer
        ) { site in
            let block: @convention(block) (AnyObject, UnsafeRawPointer?, AnyObject?)
                -> AnyObject? = { receiver, pointer, options in
                    let live = site.live()
                    let made = site.callChainedReturning(live.chained, receiver, pointer, options)
                    for observe in live.observers {
                        observe(made)
                    }
                    return made
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// Three — a class-method factory, e.g. `+[NSURLSession sessionWithConfiguration:…]`.
    public func afterFactory(
        _ target: AnyClass?,
        _ selector: Selector,
        takingThreeObjects: Void,
        kind: MethodKind = .instance,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?)
            -> Void
    ) -> SwizzleOutcome {
        install(
            target, selector, shape: .factory(objects: 3), kind: kind, observer: observer
        ) { site in
            let block: @convention(block) (
                AnyObject, AnyObject?, AnyObject?, AnyObject?
            ) -> AnyObject? = { receiver, first, second, third in
                let live = site.live()
                let made = site.callChainedReturning(live.chained, receiver, first, second, third)
                for observe in live.observers {
                    observe(receiver, first, second, third, made)
                }
                return made
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Releases observers only, never un-swizzles — a replaced IMP could break the app.
    func releaseObservers() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for site in Self.sites.values {
            site.release(owner)
        }
    }

    private func install<Body>(
        _ target: AnyClass?,
        _ selector: Selector,
        shape: HookShape,
        kind: MethodKind = .instance,
        addWhenAbsent encoding: String? = nil,
        observer: Body,
        build: (HookSite<Body>) -> IMP
    ) -> SwizzleOutcome {
        guard let target, let hooked = kind.hooked(target) else {
            return .classMissing
        }
        guard let inherited = class_getInstanceMethod(hooked, selector) else {
            guard let encoding else {
                return .selectorMissing
            }

            // A proxy (NSProxy, an Rx delegate proxy) has no method for the selector but
            // handles it in forwardInvocation:. Defining a real IMP here would intercept
            // the message before forwarding runs, silently dropping the app's own handling.
            guard !Self.forwardsMessages(hooked) else {
                return .forwardingClass
            }

            return define(
                hooked, selector, shape: shape, encoding: encoding,
                observer: observer, build: build
            )
        }

        let actual = Int(method_getNumberOfArguments(inherited))
        guard shape.arguments == actual else {
            return .signatureMismatch(expected: shape.arguments, actual: actual)
        }

        if let wanted = shape.firstArgument {
            let found = Self.argumentEncoding(inherited, at: 2) ?? "?"
            // Object encodings can be qualified; matched by prefix, BOOL must be exact.
            let matches = wanted == "@" ? found.hasPrefix("@") : found == wanted
            guard matches else {
                return .argumentKindMismatch(shape: shape.name)
            }
        }
        for (index, wanted) in shape.argumentEncodings {
            let found = Self.argumentEncoding(inherited, at: index) ?? "?"
            guard found.hasPrefix(wanted) else {
                return .argumentKindMismatch(shape: shape.name)
            }
        }
        if let index = shape.pointerArgument {
            let found = Self.argumentEncoding(inherited, at: index) ?? "?"
            guard found.hasPrefix("^")
            else {
                return .argumentKindMismatch(shape: shape.name)
            }
        }
        let returns = Self.returnEncoding(inherited)
        guard returns.hasPrefix(shape.returns) else {
            return .returnMismatch(expected: shape.returns, actual: returns)
        }

        Self.lock.lock()
        defer { Self.lock.unlock() }

        let key = Self.key(hooked, selector)
        if let existing = Self.sites[key] {
            guard existing.shape == shape, let typed = existing as? HookSite<Body> else {
                return .shapeConflict(
                    existing: existing.shape.name,
                    requested: shape.name
                )
            }

            typed.add(owner, observer)
            return .joinedExisting
        }

        let site = HookSite<Body>(shape: shape, selector: selector)
        site.add(owner, observer)
        let replacement = build(site)

        site.replacing {
            if class_addMethod(
                hooked,
                selector,
                replacement,
                method_getTypeEncoding(inherited)
            ) {
                return method_getImplementation(inherited)
            }

            return method_setImplementation(inherited, replacement)
        }

        Self.sites[key] = site
        return .installed
    }

    /// Nothing to chain — the site keeps chained nil, so observers run and call nothing.
    private func define<Body>(
        _ hooked: AnyClass,
        _ selector: Selector,
        shape: HookShape,
        encoding: String,
        observer: Body,
        build: (HookSite<Body>) -> IMP
    ) -> SwizzleOutcome {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let key = Self.key(hooked, selector)
        if let existing = Self.sites[key] {
            guard existing.shape == shape, let typed = existing as? HookSite<Body> else {
                return .shapeConflict(
                    existing: existing.shape.name,
                    requested: shape.name
                )
            }

            typed.add(owner, observer)
            return .joinedExisting
        }

        let site = HookSite<Body>(shape: shape, selector: selector)
        site.add(owner, observer)
        guard class_addMethod(hooked, selector, build(site), encoding) else {
            return .selectorMissing
        }

        Self.sites[key] = site
        return .implemented
    }
}
