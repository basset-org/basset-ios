import Foundation
import ObjectiveC

public enum SwizzleOutcome: Equatable, Sendable {
    case installed
    case joinedExisting
    /// The class never had this method and now has one that only counts. A
    /// delegate is asked `respondsToSelector:` before a framework delivers an
    /// optional callback, so a method nobody wrote is a callback nobody receives
    /// — and what it would have reported is missing from the app and from any
    /// hook that needs an existing implementation to wrap.
    case implemented
    case classMissing
    case selectorMissing
    /// The observer's shape does not match what the selector actually takes.
    /// Chaining the original through the wrong signature leaves it reading an
    /// argument from a register nothing set, so this refuses to install rather
    /// than crash inside the framework — the failure a `-[AVCaptureSession
    /// addOutput:]` hook written against the no-argument shape produced.
    case signatureMismatch(expected: Int, actual: Int)
    /// Right number of arguments, wrong kind — a `BOOL` selector reached through
    /// the object shape reads `true` as a pointer.
    case argumentKindMismatch(shape: String)
    /// The shape and the selector disagree about what comes back. A void shape
    /// chaining a method that returns something hands the caller whatever was in
    /// the return register; a factory shape chaining a void method returns an
    /// object that was never made. Both directions are wrong, which is why this
    /// names what was expected rather than only what was found.
    case returnMismatch(expected: String, actual: String)
}

/// What a selector must look like for a shape to be able to chain it. Data rather
/// than a switch per question, because every shape added otherwise adds a case to
/// each of them — and a shape whose checks are incomplete is the addOutput: crash.
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
    static let timingVoid: HookShape = .init(
        name: "timingVoid", arguments: 2, returns: "v", firstArgument: nil
    )
    /// `-captureOutput:didOutputSampleBuffer:fromConnection:` and its drop
    /// counterpart: an output, a buffer nobody here retains, and a connection.
    static let sampleBufferCallback: HookShape = .init(
        name: "sampleBufferCallback",
        arguments: 5,
        returns: "v",
        firstArgument: "@",
        pointerArgument: 3
    )

    let name: String
    /// Including self and _cmd, the way the ObjC runtime counts.
    let arguments: Int
    /// The ObjC encoding the method must return: "v" for void, "@" for an object.
    let returns: String
    /// The encoding of the first real argument, when the shape depends on it.
    /// "B" and "@" occupy the same slot and are not interchangeable.
    let firstArgument: String?
    /// The index of an argument the shape carries as a raw pointer rather than an
    /// object. A `CMSampleBufferRef` fills an object's register but is not one:
    /// received as `AnyObject?` it would be retained and released by a thunk that
    /// does not own it, so the shape refuses any selector whose slot there is not
    /// a pointer.
    var pointerArgument: Int?

    static func factory(objects count: Int) -> HookShape {
        HookShape(
            name: "factory\(count)",
            arguments: 2 + count,
            returns: "@",
            firstArgument: count == 0 ? nil : "@"
        )
    }
}

/// Whether the selector is on the type or on its instances. A class method lives
/// on the metaclass, so hooking `+sessionWithConfiguration:…` by way of the class
/// itself finds nothing.
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

/// Which handle registered an observer. Ids are handed out once and never
/// reused, so a released handle cannot be confused with a later one that happens
/// to occupy its address.
struct HookOwner: Hashable, Sendable {
    let rawValue: UInt64
}

private struct HookObserver {
    let owner: HookOwner
    let body: Any
}

private final class HookSite {
    let shape: HookShape
    let selector: Selector
    var chained: IMP?
    var observers: [HookObserver] = []

    init(shape: HookShape, selector: Selector) {
        self.shape = shape
        self.selector = selector
    }

    /// Replaced whole rather than emptied in place, because a thunk on another
    /// thread reads this array without taking the lock: swapping one array for
    /// another leaves that reader on a buffer that stays valid, where removing
    /// from the buffer it is walking does not.
    func release(_ owner: HookOwner) {
        observers = observers.filter { $0.owner != owner }
    }

    func callChained(_ receiver: AnyObject) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector) -> Void).self
        )
        original(receiver, selector)
    }

    func callChained(_ receiver: AnyObject, _ flag: Bool) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self
        )
        original(receiver, selector, flag)
    }

    func callChained(_ receiver: AnyObject, _ argument: AnyObject?) {
        guard let chained else {
            return
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self
        )
        original(receiver, selector, argument)
    }

    func callChained(_ receiver: AnyObject, _ first: AnyObject?, _ second: AnyObject?) {
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

    /// A returning method has to hand its caller the value the original produced.
    /// Dropping it would leave the app holding whatever was in the return
    /// register — the same class of fault as chaining past an argument, and the
    /// reason the shapes above refuse to touch a method that returns anything.
    func callChainedReturning(_ receiver: AnyObject) -> AnyObject? {
        guard let chained else {
            return nil
        }

        let original = unsafeBitCast(
            chained,
            to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self
        )
        return original(receiver, selector)
    }

    func callChainedReturning(_ receiver: AnyObject, _ first: AnyObject?) -> AnyObject? {
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
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var sites: [String: HookSite] = [:]
    private nonisolated(unsafe) static var ownersHandedOut: UInt64 = 0

    /// void, self, _cmd, object, pointer, object. Written out rather than copied
    /// from an existing method, because the case this serves is the one where no
    /// method exists to copy it from.
    private static let sampleBufferEncoding = "v@:@^v@"

    /// A `Swizzle` is one owner's handle on a table the whole process shares.
    /// Two handles hooking the same selector both run; one handle releasing its
    /// observers leaves the other's untouched.
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

    private static func key(_ hooked: AnyClass, _ selector: Selector) -> String {
        "\(NSStringFromClass(hooked)).\(NSStringFromSelector(selector))"
    }

    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .void, observer: observer) { site in
            let block: @convention(block) (AnyObject) -> Void = { receiver in
                site.callChained(receiver)
                for observer in site.observers {
                    (observer.body as? (AnyObject) -> Void)?(receiver)
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
                site.callChained(receiver, flag)
                for observer in site.observers {
                    (observer.body as? (AnyObject, Bool) -> Void)?(receiver, flag)
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
                    site.callChained(receiver, argument)
                    for observer in site.observers {
                        (observer.body as? (AnyObject, AnyObject?) -> Void)?(
                            receiver,
                            argument
                        )
                    }
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// A setter taking two objects — `-setSampleBufferDelegate:queue:` is the one
    /// the catalog needs, and it is how a video data output names the object that
    /// will receive every frame.
    public func after(
        _ target: AnyClass?,
        _ selector: Selector,
        takingTwoObjects: Void,
        _ observer: @escaping (AnyObject, AnyObject?, AnyObject?) -> Void
    ) -> SwizzleOutcome {
        install(target, selector, shape: .voidTwoObjects, observer: observer) { site in
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = {
                receiver, first, second in
                site.callChained(receiver, first, second)
                for observer in site.observers {
                    (observer.body as? (AnyObject, AnyObject?, AnyObject?) -> Void)?(
                        receiver, first, second
                    )
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Wrap the callback, or **define** it when the class has none.
    ///
    /// A framework asks `respondsToSelector:` before delivering an optional
    /// delegate callback, so a method the app never wrote is a callback nobody
    /// receives — and a tool that only wraps what exists cannot report what the
    /// app is not listening for. Defining one makes the framework deliver it.
    ///
    /// **Only for a callback that returns nothing and takes no completion
    /// handler.** Adding a method changes what the app appears to handle, and two
    /// shapes make that dangerous: one whose return value the framework acts on —
    /// `application(_:open:options:)` returning true makes iOS believe the URL was
    /// handled — and one carrying a completion handler, where WebKit's
    /// `decidePolicyFor…` terminates the app if the handler is called twice and
    /// hangs the navigation if it is never called. A void, handler-free callback
    /// adds an observation and no behaviour.
    ///
    /// Returns `.implemented` when the method was added rather than wrapped.
    ///
    /// **Defining is permanent, where wrapping is not.** `releaseObservers`
    /// detaches every observer, but no IMP is ever removed, so a class this
    /// defined a method on keeps responding to that selector for the life of the
    /// process, answering with a no-op once the instrument stops. Harmless for an
    /// informational callback, and one more reason the two excluded shapes stay
    /// excluded: a policy decision outliving its request decides on nobody's
    /// behalf.
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
                    site.callChained(receiver, argument)
                    for observer in site.observers {
                        (observer.body as? (AnyObject, AnyObject?) -> Void)?(
                            receiver,
                            argument
                        )
                    }
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// The two-object shape of `afterOrDefine`, under the same rule.
    ///
    /// `mapViewDidFailLoadingMap:withError:` is the case it was added for: a void
    /// callback carrying the error, which most apps never implement and so never
    /// receive — the blank map with no signal anywhere.
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
                site.callChained(receiver, first, second)
                for observer in site.observers {
                    (observer.body as? (AnyObject, AnyObject?, AnyObject?) -> Void)?(
                        receiver, first, second
                    )
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// One of the two sample-buffer callbacks, wrapped where the delegate wrote
    /// it and defined where it did not. The buffer reaches the observer as a raw
    /// pointer and is never bridged: an attachment can be read off it without
    /// owning it, where receiving it as an object would have a thunk retain and
    /// release a buffer on the delivery queue, changing what the capture measures.
    public func sampleBufferCallback(
        _ target: AnyClass?,
        _ selector: Selector,
        _ observer: @escaping (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?)
            -> Void
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
                site.callChained(receiver, output, buffer, connection)
                for observer in site.observers {
                    (
                        observer.body
                            as? (AnyObject, AnyObject?, UnsafeRawPointer?, AnyObject?)
                            -> Void
                    )?(receiver, output, buffer, connection)
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
                var started = timespec()
                clock_gettime(CLOCK_UPTIME_RAW, &started)
                site.callChained(receiver)
                var finished = timespec()
                clock_gettime(CLOCK_UPTIME_RAW, &finished)

                let startedAt = UInt64(started.tv_sec) * 1000000000 +
                    UInt64(started.tv_nsec)
                let finishedAt = UInt64(finished.tv_sec) * 1000000000 +
                    UInt64(finished.tv_nsec)
                let elapsed = finishedAt > startedAt ? finishedAt - startedAt : 0
                for observer in site.observers {
                    (observer.body as? (AnyObject, UInt64) -> Void)?(receiver, elapsed)
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// A method that makes and returns an object, hooked to see what it made.
    /// This is how a session, a manager or a web view is caught at birth when the
    /// app never hands it over: the factory is the chokepoint, and the value it
    /// returns is the thing worth registering.
    ///
    /// The original's return value is passed through untouched — the observer is
    /// told what it produced and cannot substitute it.
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
                let made = site.callChainedReturning(receiver)
                for observer in site.observers {
                    (observer.body as? (AnyObject, AnyObject?) -> Void)?(receiver, made)
                }
                return made
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// The same, for a factory taking one object — `-dataTaskWithRequest:` and
    /// its siblings, which is how nearly every task is made.
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
                let made = site.callChainedReturning(receiver, first)
                for observer in site.observers {
                    (observer.body as? (AnyObject, AnyObject?, AnyObject?) -> Void)?(
                        receiver, first, made
                    )
                }
                return made
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// And two — the completion-handler task factories, where the second object
    /// is the block. Those bypass most delegate messages, so whether a task
    /// delegate still sees their metrics is the question this shape exists to
    /// answer.
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
                    let made = site.callChainedReturning(receiver, first, second)
                    for observer in site.observers {
                        (observer
                            .body as? (AnyObject, AnyObject?, AnyObject?, AnyObject?)
                            -> Void)?(
                            receiver,
                            first,
                            second,
                            made
                        )
                    }
                    return made
                }
            return imp_implementationWithBlock(block)
        }
    }

    /// The same, for a factory taking three objects —
    /// `+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]` is the
    /// one the catalog needs, and it is a class method, so `kind: .type`.
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
                let made = site.callChainedReturning(receiver, first, second, third)
                for observer in site.observers {
                    (
                        observer.body
                            as? (AnyObject, AnyObject?, AnyObject?, AnyObject?,
                                 AnyObject?) -> Void
                    )?(receiver, first, second, third, made)
                }
                return made
            }
            return imp_implementationWithBlock(block)
        }
    }

    /// Drops every observer this handle registered, from every site it
    /// registered on, and leaves the hooks themselves installed and still
    /// chaining the original. An instrument that deactivates stops being told
    /// about the calls; it does not un-swizzle, because restoring an IMP another
    /// SDK has since replaced is what breaks the app.
    ///
    /// Without this an instrument stopped and started again registers a second
    /// copy of its observers and reports every call twice.
    func releaseObservers() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for site in Self.sites.values {
            site.release(owner)
        }
    }

    private func install(
        _ target: AnyClass?,
        _ selector: Selector,
        shape: HookShape,
        kind: MethodKind = .instance,
        addWhenAbsent encoding: String? = nil,
        observer: Any,
        build: (HookSite) -> IMP
    ) -> SwizzleOutcome {
        guard let target, let hooked = kind.hooked(target) else {
            return .classMissing
        }
        guard let inherited = class_getInstanceMethod(hooked, selector) else {
            guard let encoding else {
                return .selectorMissing
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
            // An object encoding can be qualified ("@?" for a block, "@\"NSString\""),
            // so it is matched by prefix where BOOL must be exact.
            let matches = wanted == "@" ? found.hasPrefix("@") : found == wanted
            guard matches else {
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
            precondition(
                existing.shape == shape,
                "\(key) is already hooked as \(existing.shape.name) and cannot also be \(shape.name)"
            )
            existing.observers.append(HookObserver(owner: owner, body: observer))
            return .joinedExisting
        }

        let site = HookSite(shape: shape, selector: selector)
        site.observers.append(HookObserver(owner: owner, body: observer))
        let replacement = build(site)

        if class_addMethod(
            hooked,
            selector,
            replacement,
            method_getTypeEncoding(inherited)
        ) {
            site.chained = method_getImplementation(inherited)
        } else {
            site.chained = method_setImplementation(inherited, replacement)
        }

        Self.sites[key] = site
        return .installed
    }

    /// Nothing to chain and nothing to validate against: the shape is the whole
    /// description of a method that does not exist yet. The site keeps `chained`
    /// nil, so the observers run and call nothing.
    private func define(
        _ hooked: AnyClass,
        _ selector: Selector,
        shape: HookShape,
        encoding: String,
        observer: Any,
        build: (HookSite) -> IMP
    ) -> SwizzleOutcome {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let key = Self.key(hooked, selector)
        if let existing = Self.sites[key] {
            precondition(
                existing.shape == shape,
                "\(key) is already hooked as \(existing.shape.name) and cannot also be \(shape.name)"
            )
            existing.observers.append(HookObserver(owner: owner, body: observer))
            return .joinedExisting
        }

        let site = HookSite(shape: shape, selector: selector)
        site.observers.append(HookObserver(owner: owner, body: observer))
        guard class_addMethod(hooked, selector, build(site), encoding) else {
            return .selectorMissing
        }

        Self.sites[key] = site
        return .implemented
    }
}
