import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// How much of SwiftUI's rendered output is actually changing.
///
/// `swiftui.host.updates` says the hosting view laid out; this says whether
/// anything came of it. A screen laying out sixty times a second while its
/// display list never changes is a re-render loop producing no pixels, which is
/// the shape of the bug and not merely its cost.
///
/// **Read the item count before the change count.** `List` and the other
/// collection-backed containers render their rows through UIKit cells, so the
/// display list at the hosting view holds roughly one item and does not move when
/// row content changes — a host laying out 2023 times a second with the seed
/// fixed looks exactly like a re-render loop and is not one. An item count near
/// one means the screen draws through UIKit, and `uikit.view.layoutPass` is the
/// answer for those.
///
/// **Tier-3 mechanism: it fails to silence.** The renderer is reached by walking
/// property names through `Mirror`, and SwiftUI has moved it twice — `renderer`,
/// then `_base.renderer`, then `_base.viewGraph.renderer`. A rename returns nil
/// rather than raising, so an instrument reporting only what it read would look
/// like a quiet app. Every reading carries `mechanismStatus`: *could not read* is
/// a different answer from *nothing changed*.
final class DisplayListChurn: StreamingInstrument {
    private struct Sample: Equatable {
        let itemCount: Int
        let seed: UInt32?
        let fingerprint: Int
    }

    static let id: InstrumentWireID = .swiftUIDisplayListChurn
    static let entity = Entity.WireID.swiftUIDisplayList

    /// Four times a second, over at most four hosts. `Mirror` is not free and
    /// this runs on the main queue; a sample rate that competed with the render
    /// loop would change what it measures.
    ///
    /// The change count therefore saturates: it counts samples that differed, so
    /// a busy second reports four however busy it was. The seed is the
    /// quantitative measure — a re-render storm advances it by thousands a second
    /// where identity churn advances it by hundreds, and both report four changes.
    private static let sampleInterval = 0.25
    private static let hostCeiling = 4

    private let lock: NSLock = .init()
    private var lastSample: [ObjectIdentifier: Sample] = [:]
    private var changes: UInt64 = 0
    private var latest: Sample?
    private var generation: String?
    private var status = "not sampled yet"
    private var sampler: DispatchSourceTimer?

    #if canImport(UIKit)
    private let hosts: WeakRegistry<UIViewController> = .init()
    #endif

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            guard SwiftUIHost.kind(of: receiver) != nil,
                  let controller = receiver as? UIViewController
            else {
                return
            }

            self?.hosts.add(controller)
        }

        // On the main queue because the display list is written there: a
        // background sampler would race the render it is describing. Between
        // run-loop turns rather than inside a layout hook — reading a view tree
        // from a swizzled layout call stack induces AttributeGraph cycles.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.sampleInterval,
            repeating: Self.sampleInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self, context.isActive else {
                return
            }

            sample()
        }
        timer.activate()
        sampler = timer

        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self else {
                return
            }

            lock.lock()
            let reported = (
                status: status,
                generation: generation,
                latest: latest,
                changes: changes,
                hosts: UInt32(hosts.count)
            )
            changes = 0
            lock.unlock()

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.mechanismStatus(reported.status))
            out.put(.hostCount(reported.hosts))
            if let generation = reported.generation {
                out.put(.ivarPathGeneration(generation))
            }
            if let latest = reported.latest {
                out.put(.displayListItemCount(UInt32(latest.itemCount)))
                if let seed = latest.seed {
                    out.put(.displayListSeed(seed))
                }
            }
            out.put(.displayListChangeCount(reported.changes))
        }
        #endif
    }

    func stopObserving() {
        sampler?.cancel()
        sampler = nil
        lock.lock()
        lastSample.removeAll()
        changes = 0
        latest = nil
        generation = nil
        status = "not sampled yet"
        lock.unlock()
    }

    #if canImport(UIKit)
    private func sample() {
        let live = hosts.all.prefix(Self.hostCeiling)
        guard !live.isEmpty else {
            record(status: "no swiftui host on screen")
            return
        }

        for controller in live {
            switch SwiftUIReflection.renderer(of: controller.viewIfLoaded) {
            case .noHostingView:
                record(status: "host has no view loaded")
            case .pathDeadEnded(let generation, let step):
                // The loud half of failing open: the reading says the mechanism
                // did not reach, not that nothing happened.
                record(status: "renderer unreachable at \(generation):\(step)")
            case .reached(let renderer, let generation):
                guard let shape = SwiftUIReflection.displayList(in: renderer) else {
                    record(status: "renderer reached, no display list under it")
                    continue
                }

                note(
                    Sample(
                        itemCount: shape.itemCount,
                        seed: shape.seed,
                        fingerprint: shape.fingerprint
                    ),
                    for: ObjectIdentifier(controller),
                    generation: generation
                )
            }
        }
    }

    private func note(_ sample: Sample, for key: ObjectIdentifier, generation: String) {
        lock.lock()
        if let previous = lastSample[key], previous != sample {
            changes += 1
        }
        lastSample[key] = sample
        latest = sample
        self.generation = generation
        status = "ok"
        lock.unlock()
    }

    private func record(status: String) {
        lock.lock()
        self.status = status
        lock.unlock()
    }
    #endif
}

/// Which SwiftUI screen the user reached, named as the developer named it.
///
/// The type name alone is not enough. `AnyView` erases it, and dropping the
/// reading when that happens is the wrong end: an absent screen and a screen that
/// never appeared read the same in a capture.
///
/// So both names go out — the unwrapped type and the navigation title — and the
/// reading is marked when the type erased itself. Either one can be the useless
/// one.
final class HostAppear: StreamingInstrument {
    static let id: InstrumentWireID = .swiftUIHostAppear
    static let entity = Entity.WireID.swiftUIHost

    /// A screen that loaded and never appeared leaves an entry behind. The cap
    /// bounds that at a size no real app reaches, so a leak cannot grow with
    /// uptime.
    private static let pendingCeiling = 64

    private let lock: NSLock = .init()
    private var loadedAt: [ObjectIdentifier: UInt64] = [:]
    private var identifiers: [ObjectIdentifier: UInt32] = [:]

    #if canImport(UIKit)
    private let hosts: WeakRegistry<UIViewController> = .init()
    #endif

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        hosts.attachAndFollow { [weak self] controller, instance in
            guard let self else {
                return
            }

            lock.lock()
            identifiers[ObjectIdentifier(controller)] = instance
            lock.unlock()
        }

        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidLoad)
        ) { [weak self] receiver in
            self?.loaded(receiver, context)
        }

        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.appeared(receiver, context)
        }
        #endif
    }

    func stopObserving() {
        lock.lock()
        loadedAt.removeAll()
        identifiers.removeAll()
        lock.unlock()
    }

    #if canImport(UIKit)
    private func loaded(_ receiver: AnyObject, _ context: Context) {
        guard SwiftUIHost.kind(of: receiver) != nil else {
            return
        }

        lock.lock()
        if loadedAt.count >= Self.pendingCeiling {
            loadedAt.removeAll()
        }
        loadedAt[ObjectIdentifier(receiver)] = context.clock.now().nanoseconds
        lock.unlock()
    }

    private func appeared(_ receiver: AnyObject, _ context: Context) {
        guard let kind = SwiftUIHost.kind(of: receiver),
              let controller = receiver as? UIViewController
        else {
            return
        }

        hosts.add(controller)

        let key = ObjectIdentifier(receiver)
        lock.lock()
        let loaded = loadedAt.removeValue(forKey: key)
        let instance = identifiers[key]
        lock.unlock()

        let root = SwiftUIHost.rootView(of: receiver)

        context.emit { out in
            out.put(.hostKind(kind.rawValue))
            out.put(.hostRootViewType(root.name))
            out.put(.hostRootViewOpaque(root.isOpaque))
            out.put(.viewControllerClass(String(describing: type(of: receiver))))
            if let title = SwiftUIHost.title(of: controller) {
                out.put(.hostNavigationTitle(title))
            }
            if let loaded {
                out.put(.hostAppearNanoseconds(context.clock.now().nanoseconds - loaded))
            }
            if let instance {
                out.put(.instanceId(instance))
            }
            if let hostingView = SwiftUIHost.hostingViewClass(of: controller) {
                out.put(.hostViewClass(NSStringFromClass(hostingView)))
            }
            out.put(.hostCount(UInt32(hosts.count)))
        }
    }
    #endif
}

/// How hard SwiftUI is working, measured where SwiftUI meets UIKit.
///
/// A re-render loop is the SwiftUI failure with the largest gap between how
/// often developers hit it and how little tooling sees it. It is invisible to
/// `uikit.view.layoutPass`, which counts every view in the process and drowns
/// one host in the app's ordinary layout traffic.
///
/// The hook is installed on the hosting view's class alone — obtained from a
/// live instance, never looked up by name — so only SwiftUI content pays for it.
///
/// **Nothing but counting happens in the hook, and that is a correctness rule
/// rather than a budget.** Capture work on a swizzled layout call stack induces
/// AttributeGraph cycles in the app. Reading a view tree or reflecting a display
/// list from here reproduces that.
final class HostUpdates: StreamingInstrument, @unchecked Sendable {
    static let id: InstrumentWireID = .swiftUIHostUpdates
    static let entity = Entity.WireID.swiftUIHost

    private static let passes: TallySlot = .first
    private static let totalNanoseconds: TallySlot = .second
    private static let peakNanoseconds: TallySlot = .third

    private let lock: NSLock = .init()
    private var hookedClasses: Set<ObjectIdentifier> = []
    private var lastHookedName: String?

    #if canImport(UIKit)
    private let hosts: WeakRegistry<UIViewController> = .init()
    #endif

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.appeared(receiver, context)
        }

        context.flush(every: .seconds(1)) { [weak self] out, window in
            let passes = context.tally.take(Self.passes)
            guard passes > 0 else {
                return
            }

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.passCount(passes))
            out.put(.totalNanoseconds(context.tally.take(Self.totalNanoseconds)))
            out.put(.peakNanoseconds(context.tally.take(Self.peakNanoseconds)))
            guard let self else {
                return
            }

            out.put(.hostCount(UInt32(hosts.count)))
            lock.lock()
            let name = lastHookedName
            lock.unlock()
            if let name {
                out.put(.hostViewClass(name))
            }
        }
        #endif
    }

    func stopObserving() {
        lock.lock()
        hookedClasses.removeAll()
        lastHookedName = nil
        lock.unlock()
    }

    #if canImport(UIKit)
    private func appeared(_ receiver: AnyObject, _ context: Context) {
        guard SwiftUIHost.kind(of: receiver) != nil,
              let controller = receiver as? UIViewController,
              let hostingView = SwiftUIHost.hostingViewClass(of: controller)
        else {
            return
        }

        hosts.add(controller)

        let key = ObjectIdentifier(hostingView)
        lock.lock()
        let alreadyHooked = hookedClasses.contains(key)
        if !alreadyHooked {
            hookedClasses.insert(key)
            lastHookedName = NSStringFromClass(hostingView)
        }
        lock.unlock()
        guard !alreadyHooked else {
            return
        }

        // Off this call stack on purpose. Installing a hook from inside a
        // running hook re-enters the swizzle table's lock, and the delay
        // costs one run-loop turn of a counter that aggregates over a second.
        DispatchQueue.main.async { [weak self] in
            self?.hookLayout(of: hostingView, context)
        }
    }

    private func hookLayout(of hostingView: AnyClass, _ context: Context) {
        let hot = context.hotPath
        _ = context.swizzle.timing(hostingView, #selector(UIView.layoutSubviews)) {
            _, elapsed in
            guard hot.isActive else {
                return
            }

            hot.add(Self.passes)
            hot.add(Self.totalNanoseconds, elapsed)
            hot.raise(Self.peakNanoseconds, to: elapsed)
        }
    }
    #endif
}

/// Sheets and modal SwiftUI screens, in the order they opened and closed.
///
/// "The sheet does not appear" and "the sheet closes itself" are ordinary
/// SwiftUI bug reports with no signal behind them, because the presentation is
/// driven by a binding the SDK cannot see. What it can see is UIKit doing the
/// presenting underneath, which answers the question that matters first: did the
/// presentation happen at all.
final class Presentation: StreamingInstrument {
    static let id: InstrumentWireID = .swiftUIPresentation
    static let entity = Entity.WireID.swiftUIPresentation

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.settled(receiver, transition: "presented", context)
        }

        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidDisappear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.settled(receiver, transition: "dismissed", context)
        }
        #endif
    }

    func stopObserving() {}

    #if canImport(UIKit)
    private func settled(_ receiver: AnyObject, transition: String, _ context: Context) {
        guard let kind = SwiftUIHost.kind(of: receiver),
              let controller = receiver as? UIViewController
        else {
            return
        }

        // Presented rather than pushed or installed as a root. A screen that
        // arrived by navigation is `swiftui.host.appear`'s to report, and
        // emitting it here as well would double every reading.
        if transition == "presented" {
            guard controller.presentingViewController != nil else {
                return
            }
        } else {
            guard controller.isBeingDismissed else {
                return
            }
        }

        let root = SwiftUIHost.rootView(of: receiver)
        context.emit { out in
            out.put(.detail(transition))
            out.put(.presentationKind(Self.style(of: controller)))
            out.put(.presentedRootViewType(root.name))
            out.put(.hostKind(kind.rawValue))
            if let title = SwiftUIHost.title(of: controller) {
                out.put(.hostNavigationTitle(title))
            }
        }
    }

    private static func style(of controller: UIViewController) -> String {
        switch controller.modalPresentationStyle {
        case .fullScreen: "fullScreen"
        case .pageSheet: "pageSheet"
        case .formSheet: "formSheet"
        case .currentContext: "currentContext"
        case .custom: "custom"
        case .overFullScreen: "overFullScreen"
        case .overCurrentContext: "overCurrentContext"
        case .popover: "popover"
        case .automatic: "automatic"
        case .none: "none"
        @unknown default: "unknown"
        }
    }
    #endif
}

/// What a window of log records says, separated from the reading of them.
///
/// A re-render loop repeats one violation thousands of times a second, so the
/// useful shape is "this rule broke, this many times" rather than one reading
/// per occurrence. Pure, so the rule can be tested on the host without a log
/// store to read from.
struct RuntimeIssueDigest {
    struct Subject: Equatable {
        let subsystem: String
        let category: String
        let message: String
        let count: UInt64
    }

    private struct Key: Hashable {
        let subsystem: String
        let category: String
        let message: String
    }

    static let admittedSwiftUICategories: Set<String> = ["Changed Body Properties"]

    let subjects: [Subject]
    /// Distinct subjects the ceiling left out. Reported rather than dropped
    /// quietly: "sixteen kinds of problem" and "sixteen of many" are different
    /// findings, and a capture that cannot tell them apart is misleading.
    let omitted: Int

    var isEmpty: Bool {
        subjects.isEmpty
    }

    init(_ records: [LogRecord], ceiling: Int) {
        let admitted = records.filter(Self.admits)

        var counts = [Key: UInt64]()
        for record in admitted {
            counts[
                Key(
                    subsystem: record.subsystem,
                    category: record.category,
                    message: record.message
                ),
                default: 0
            ] += 1
        }

        // By count, then by message. Ordering on arrival would make two captures
        // of the same bug disagree about which violation mattered most.
        let ranked =
            counts
                .map {
                    Subject(
                        subsystem: $0.key.subsystem,
                        category: $0.key.category,
                        message: $0.key.message,
                        count: $0.value
                    )
                }
                .sorted {
                    ($0.count, $1.message) > ($1.count, $0.message)
                }

        subjects = Array(ranked.prefix(ceiling))
        omitted = max(0, ranked.count - subjects.count)
    }

    /// Severity first, because a subsystem is not uniformly diagnostic.
    ///
    /// `com.apple.attributegraph` carries the non-fatal precondition failures
    /// worth reading *and* lines like "ignoring retroactive Equatable conformance
    /// on type __C.AGAttribute". Filtering on level rather than on a category
    /// deny-list keeps the one and drops the other without having to know every
    /// category Apple might add.
    ///
    /// `com.apple.runtime-issues` exists only to carry them, so its level does
    /// not need checking. `com.apple.SwiftUI` is ordinary framework logging with
    /// one category worth reading, and `_logChanges()` emits it at `.info` —
    /// below the severity bar, which is why that one is named explicitly.
    static func admits(_ record: LogRecord) -> Bool {
        switch record.subsystem {
        case "com.apple.runtime-issues": true
        case "com.apple.SwiftUI": admittedSwiftUICategories.contains(record.category)
        default: record.level.isDiagnostic
        }
    }
}

/// SwiftUI reports its own undefined behaviour, in release, on every device, and
/// nobody reads it. `StoredLocationBase.set(_:transaction:)` and its neighbours
/// log a **fault** to `com.apple.runtime-issues`; Xcode's purple banner is a
/// presentation of a record that exists whether or not a debugger is attached.
///
/// What arrives is the rule that was broken and when. There is no backtrace in
/// an `OSLogEntryLog`, so this instrument answers "the app modified state during
/// a view update at 14:22:11" and never "in `CartView`". Pair it with
/// `swiftui.host.appear` to bound which screen was on.
final class RuntimeIssues: StreamingInstrument {
    static let id: InstrumentWireID = .swiftUIRuntimeIssues
    static let entity = Entity.WireID.swiftUIRuntimeIssue

    /// `runtime-issues` carries SwiftUI's own violations. `attributegraph`
    /// carries the non-fatal precondition failures, which are the survivable half
    /// of the family that otherwise aborts. `SwiftUI` carries `_logChanges()`
    /// output, which only exists if the app asked for it — free when present,
    /// absent otherwise, and filtered by category so ordinary framework chatter
    /// does not crowd out a fault.
    private static let subsystems = [
        "com.apple.runtime-issues",
        "com.apple.attributegraph",
        "com.apple.SwiftUI",
    ]
    /// One flush describes a burst rather than transcribing it: a re-render storm
    /// repeats the same violation thousands of times, and thousands of identical
    /// readings would spend a request's whole budget saying one thing.
    private static let subjectsPerFlush = 16

    private let reader: LogStoreReader = .init(subsystems: RuntimeIssues.subsystems)

    init() {}

    /// The window goes on every row, not only the first. One flush becomes one
    /// entity per distinct violation, so a window on the first row alone leaves
    /// every sibling carrying a count with nothing to divide it by.
    private static func write(
        _ digest: RuntimeIssueDigest,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        for (index, subject) in digest.subjects.enumerated() {
            if index == 0 {
                put(subject, over: window, into: &out)
                continue
            }
            out.also(Entity.WireID.swiftUIRuntimeIssue) { sibling in
                put(subject, over: window, into: &sibling)
            }
        }
        guard digest.omitted > 0 else {
            return
        }

        out.also(Entity.WireID.swiftUIRuntimeIssue) { sibling in
            sibling.put(.windowNanoseconds(window.nanoseconds))
            sibling.put(.mechanismStatus("truncated: \(digest.omitted) more"))
        }
    }

    private static func put(
        _ subject: RuntimeIssueDigest.Subject,
        over window: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.windowNanoseconds(window.nanoseconds))
        out.put(.logSubsystem(subject.subsystem))
        out.put(.logCategory(subject.category))
        out.put(.logMessage(subject.message))
        out.put(.occurrenceCount(subject.count))
    }

    func observe(_ context: Context) {
        // Fifteen seconds is what the mechanism costs, not what would be nice. On
        // device an `OSLogStore` drain takes roughly ten seconds of wall clock
        // however little there is to read, so a two-second timer never idles — it
        // runs back to back and still delivers every ten. An interval the
        // instrument cannot keep is a rate nobody can reason about.
        //
        // Violations are counted over the whole interval, so asking less often
        // loses nothing but latency.
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records):
                let digest = RuntimeIssueDigest(records, ceiling: Self.subjectsPerFlush)
                guard !digest.isEmpty else {
                    return
                }

                Self.write(digest, over: window, into: &out)
            }
        }
    }

    func stopObserving() {}
}

/// Recognising the UIKit objects SwiftUI puts its content inside, and reading
/// the developer's own type name back out of them.
///
/// Recognition is by class name rather than by conformance. A marker protocol on
/// `UIHostingController` would catch every specialization with nothing to decay,
/// but it means importing SwiftUI — and a zero-dependency SDK does not put the
/// largest UI framework on the link line of an app that does not use it. The name
/// `UIHostingController` has been stable since iOS 13; the leaf drawing classes
/// are what churn, and nothing here matches on one.
///
/// Every lookup fails **open**: an unrecognised host is reported as `.unknown`
/// rather than skipped, because a rename would otherwise turn this domain
/// silent instead of loud.
enum SwiftUIHost {
    enum Kind: String {
        case hostingController
        case navigationStack
        case presentation
        case unknown
    }

    struct RootView {
        let name: String
        /// The type erased itself before we could read a name a developer would
        /// recognise. `AnyView` is the common case, and it is the reason a
        /// navigation title is worth emitting beside this.
        let isOpaque: Bool
    }

    /// Types that describe how a view is presented rather than which view it is.
    /// Unwrapping one moves toward the name a developer wrote.
    private static let transparentWrappers: Set<String> = [
        "ModifiedContent",
        "LazyView",
        "ParameterizedLazyView",
        "_ViewModifier_Content",
        "EnvironmentKeyWritingModifier",
    ]

    /// Nil for anything that is not hosting SwiftUI content.
    static func kind(of object: AnyObject) -> Kind? {
        kind(fromDescription: String(describing: type(of: object)))
    }

    static func kind(fromDescription name: String) -> Kind? {
        if name.hasPrefix("UIHostingController") {
            return .hostingController
        }
        if name.hasPrefix("NavigationStackHostingController") {
            return .navigationStack
        }
        if name.hasPrefix("PresentationHostingController") {
            return .presentation
        }
        guard name.contains("HostingController") else {
            return nil
        }

        return .unknown
    }

    /// `UIHostingController<ModifiedContent<ContentView, …>>` is the shape that
    /// actually arrives, so the outer wrapper is stripped and modifiers are
    /// unwrapped until a name survives.
    ///
    /// A stripped `AnyView` is reported rather than dropped: in a capture, an
    /// absent screen and a screen that never appeared read the same.
    static func rootView(of object: AnyObject) -> RootView {
        rootView(fromDescription: String(describing: type(of: object)))
    }

    static func rootView(fromDescription description: String) -> RootView {
        guard var current = firstGenericArgument(of: description) else {
            return RootView(name: description, isOpaque: true)
        }

        // Bounded rather than `while true`: the input is a type name from a
        // framework, and an unbounded loop over one is a hang waiting for a
        // shape nobody anticipated.
        for _ in 0 ..< 16 {
            let (base, arguments) = split(current)
            if base == "AnyView" {
                return RootView(name: "AnyView", isOpaque: true)
            }
            guard Self.transparentWrappers.contains(base),
                  let first = arguments.first
            else {
                return RootView(name: base, isOpaque: base.isEmpty)
            }

            current = first
        }
        return RootView(name: split(current).base, isOpaque: true)
    }

    static func firstGenericArgument(of description: String) -> String? {
        let (_, arguments) = split(description)
        return arguments.first
    }

    /// The generic arguments of a type name, respecting nesting — a regular
    /// expression over `<…>` splits `ModifiedContent<Foo<A, B>, C>` in the wrong
    /// place.
    static func split(_ description: String) -> (base: String, arguments: [String]) {
        guard let open = description.firstIndex(of: "<") else {
            return (description, [])
        }

        let base = String(description[description.startIndex ..< open])
        var arguments = [String]()
        var depth = 0
        var current = ""

        for character in description[description.index(after: open)...] {
            switch character {
            case "<":
                depth += 1
                current.append(character)
            case ">":
                if depth == 0 {
                    arguments.append(current.trimmingCharacters(in: .whitespaces))
                    return (base, arguments.filter { !$0.isEmpty })
                }
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        arguments.append(current.trimmingCharacters(in: .whitespaces))
        return (base, arguments.filter { !$0.isEmpty })
    }

    #if canImport(UIKit)
    /// Frequently the only name a person would recognise, and free to read.
    /// Emitted beside the type name because either one can be the useless one.
    static func title(of controller: UIViewController) -> String? {
        let candidates = [
            controller.navigationItem.title,
            controller.title,
            controller.tabBarItem?.title,
        ]
        return candidates.compactMap(\.self).first { !$0.isEmpty }
    }

    /// Read off a live instance rather than looked up by name, so no private
    /// class name is written into the binary. This is also the only way to
    /// reach `_UIHostingView`'s class without importing SwiftUI.
    static func hostingViewClass(of controller: UIViewController) -> AnyClass? {
        guard let view = controller.viewIfLoaded else {
            return nil
        }

        return object_getClass(view)
    }
    #endif
}

/// Reading SwiftUI's render state out of a hosting view by property name.
///
/// A tier-3 mechanism: no private symbol is linked or referenced, only Swift's
/// own reflection. It passes App Store review, and it couples to SwiftUI's
/// internal shape, which has moved twice in two years.
///
/// **`Mirror`, not `object_getIvar`.** The ivar pair reads whatever the name
/// resolves to, which against a struct field is undefined behaviour rather than
/// merely a wrong answer. An `ivar_getTypeEncoding` guard does not fix it: on a
/// device, `_UIHostingView` came back with every encoding empty — Swift stored
/// properties carry no ObjC type encoding — so the guard rejected the whole graph
/// and the instrument reported the renderer unreachable with `_base` sitting
/// right there.
///
/// `Mirror` is type-safe by construction, sees Swift stored properties as the
/// properties they are, and answers a name that no longer exists with nil rather
/// than a reinterpreted pointer. The remaining failure mode is the honest one: a
/// renamed property returns nil, so every result carries how it ended.
enum SwiftUIReflection {
    enum Reach {
        case reached(Any, generation: String)
        case pathDeadEnded(generation: String, atStep: String)
        case noHostingView
    }

    struct DisplayListShape {
        let itemCount: Int
        /// `ViewUpdater.seed`, which SwiftUI advances once per update. It sits
        /// beside `lastList` as `Seed { value: UInt16 }` — one number that answers
        /// the whole question, where the fallback below has to infer it.
        let seed: UInt32?
        /// What the list *says*, condensed, for when no seed is found. Item
        /// count alone does not move when a re-render changes content without
        /// changing structure, which is most of them, so this hashes the
        /// identity and version each item carries.
        let fingerprint: Int
    }

    /// SwiftUI has moved the renderer twice. Tried newest-first rather than
    /// selected by `#available`, because the OS version says which path *should*
    /// work and the object says which one does — and on a release this table has
    /// never seen, trying is the only way to find out.
    static let rendererPaths: [(generation: String, path: [String])] = [
        ("26", ["_base", "viewGraph", "renderer"]),
        ("18.1", ["_base", "renderer"]),
        ("18.0", ["renderer"]),
    ]

    /// The chain from the renderer down. `ViewRenderer` holds the platform
    /// renderer under `renderer`, which holds the view updater, which holds
    /// `lastList`. On device, `ViewRenderer.renderer` is nil for a view that has
    /// laid out but never been in a window, so the walk keeps going rather than
    /// stopping at the first object it can name.
    private static let carriers: Set<String> = [
        "renderer", "viewCache", "list", "displayList", "base", "storage",
        "viewGraph", "graph", "state",
    ]

    static func renderer(of hostingView: Any?) -> Reach {
        guard let hostingView else {
            return .noHostingView
        }

        var deepest: Reach?
        for candidate in rendererPaths {
            var current: Any = hostingView
            var failed: String?
            for step in candidate.path {
                guard let next = child(of: current, named: step) else {
                    failed = step
                    break
                }

                current = next
            }
            if let failed {
                if deepest == nil {
                    deepest = .pathDeadEnded(
                        generation: candidate.generation,
                        atStep: failed
                    )
                }
                continue
            }
            return .reached(current, generation: candidate.generation)
        }
        return deepest ?? .pathDeadEnded(generation: "none", atStep: "")
    }

    /// A stored property by name, with `Optional` unwrapped. Reflection reports
    /// an optional as its own one-child structure, so a path that did not unwrap
    /// would stop at the first optional property in it.
    static func child(of subject: Any, named name: String) -> Any? {
        for child in Mirror(reflecting: subject).children where child.label == name {
            return unwrapped(child.value)
        }
        return nil
    }

    static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        guard let some = mirror.children.first else {
            return nil
        }

        return unwrapped(some.value)
    }

    /// The display list, by the one property name that identifies it.
    ///
    /// Searching for any child called `items` that is a collection matches
    /// something holding a single element that never moves through a deliberate
    /// re-render storm — while reporting success. Finding an array is not finding
    /// the display list.
    ///
    /// `lastList` is the name SwiftUI's view updater holds it under. Requiring it
    /// means a wrong turn produces nil, which the instrument reports, rather than
    /// a plausible number nobody can falsify.
    static func displayList(in renderer: Any, depth: Int = 0) -> DisplayListShape? {
        guard depth < 6 else {
            return nil
        }

        let mirror = Mirror(reflecting: renderer)

        // Whatever holds `lastList` is the view updater, and the seed sits on it
        // rather than on the list — so the object that matched is read, not just
        // the list it pointed at.
        if let list = mirror.children.first(where: { $0.label == "lastList" }),
           let unwrappedList = unwrapped(list.value)
        {
            return shape(of: unwrappedList, updatedBy: renderer)
        }

        for child in mirror.children {
            guard let label = child.label, Self.carriers.contains(label) else {
                continue
            }
            guard let value = unwrapped(child.value) else {
                continue
            }

            if let found = displayList(in: value, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func shape(of list: Any, updatedBy updater: Any) -> DisplayListShape? {
        guard let items = child(of: list, named: "items") else {
            return nil
        }

        let mirror = Mirror(reflecting: items)
        guard mirror.displayStyle == .collection else {
            return nil
        }

        var hasher = Hasher()
        var count = 0
        for item in mirror.children {
            count += 1
            hasher.combine(count)
            identify(item.value, into: &hasher)
        }
        return DisplayListShape(
            itemCount: count,
            seed: seed(of: updater),
            fingerprint: hasher.finalize()
        )
    }

    /// `Seed { value: UInt16 }` on the view updater. Widened on the way out
    /// because sixteen bits wrap in an afternoon of updates, and a counter that
    /// silently restarts is worse than one that is plainly large.
    private static func seed(of updater: Any) -> UInt32? {
        guard let seed = child(of: updater, named: "seed") else {
            return nil
        }

        for inner in Mirror(reflecting: seed).children where inner.label == "value" {
            if let value = inner.value as? UInt16 {
                return UInt32(value)
            }
            if let value = inner.value as? UInt32 {
                return value
            }
        }
        return nil
    }

    /// An item's identity and version, which is what a redraw changes. Read by
    /// name and skipped when absent, so an unfamiliar item shape contributes its
    /// position rather than breaking the walk.
    private static func identify(_ item: Any, into hasher: inout Hasher) {
        for child in Mirror(reflecting: item).children {
            guard let label = child.label,
                  label == "identity" || label == "version" || label == "seed"
            else {
                continue
            }

            for inner in Mirror(reflecting: child.value).children
                where inner.label == "value"
            {
                if let value = inner.value as? UInt32 {
                    hasher.combine(value)
                }
                if let value = inner.value as? UInt16 {
                    hasher.combine(value)
                }
                if let value = inner.value as? Int {
                    hasher.combine(value)
                }
            }
        }
    }
}
