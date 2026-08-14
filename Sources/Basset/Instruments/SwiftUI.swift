import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Change count on SwiftUI's display list — item count near 1 means UIKit-backed, not a loop.
final class DisplayListChurn: Streamable, PlainInstrument {
    private struct Sample: Equatable {
        let itemCount: Int
        let seed: UInt32?
        let fingerprint: Int
    }

    private struct State {
        /// Keyed by instance number, not address: reused addresses look unchanged.
        var lastSample: [UInt32: Sample] = [:]
        var changes: UInt64 = 0
        var latest: Sample?
        var generation: String?
        var status = "not sampled yet"
    }

    static let id: InstrumentID = .swiftUIDisplayListChurn
    static let entity = Entity.ID.swiftUIDisplayList

    /// Change count saturates at 4/sec — the seed's rate of advance is the real measure.
    private static let sampleInterval = 0.25
    private static let hostCeiling = 4

    private let guarded: Mutex<State> = .init(State())
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

        // Without this, first reading is "no host on screen" until the user navigates.
        DispatchQueue.main.async { [weak self] in
            guard context.isActive else {
                return
            }

            SwiftUIHost.onScreen().forEach { self?.hosts.add($0) }
        }

        // Off the layout call stack — reading from inside one induces AttributeGraph cycles.
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

            let hostCount = UInt32(hosts.count)
            let reported = guarded.withLock { state in
                defer { state.changes = 0 }
                return (
                    status: state.status,
                    generation: state.generation,
                    latest: state.latest,
                    changes: state.changes,
                    hosts: hostCount
                )
            }

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
        guarded.withLock { $0 = State() }
    }

    #if canImport(UIKit)
    private func sample() {
        // On screen, not merely alive — a pushed-behind host would take a ceiling slot.
        let live = hosts.tracked
            .filter { $0.object.viewIfLoaded?.window != nil }
            .suffix(Self.hostCeiling)
        guard !live.isEmpty else {
            record(status: "no swiftui host on screen")
            return
        }

        for (controller, instance) in live {
            switch SwiftUIReflection.renderer(of: controller.viewIfLoaded) {
            case .noHostingView:
                record(status: "host has no view loaded")
            case .pathDeadEnded(let generation, let step):
                // Fails loud: says the mechanism didn't reach, not that nothing happened.
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
                    for: instance,
                    generation: generation
                )
            }
        }

        forget(everythingBut: Set(live.map(\.instance)))
    }

    /// Bounds the dictionary, which otherwise grows for as long as a capture visits screens.
    private func forget(everythingBut live: Set<UInt32>) {
        guarded.withLock { $0.lastSample = $0.lastSample.filter { live.contains($0.key) } }
    }

    private func note(_ sample: Sample, for key: UInt32, generation: String) {
        guarded.withLock { state in
            if let previous = state.lastSample[key], previous != sample {
                state.changes += 1
            }

            state.lastSample[key] = sample
            state.latest = sample
            state.generation = generation
            state.status = "ok"
        }
    }

    private func record(status: String) {
        guarded.withLock { $0.status = status }
    }
    #endif
}

/// Which SwiftUI screen appeared, by view and controller type — a title would be the user's.
final class HostAppear: Streamable, PlainInstrument {
    private struct State {
        var loadedAt: [ObjectIdentifier: UInt64] = [:]
        var identifiers: [ObjectIdentifier: UInt32] = [:]
    }

    static let id: InstrumentID = .swiftUIHostAppear
    static let entity = Entity.ID.swiftUIHost

    /// Caps entries for screens that never appeared, so a leak can't grow with uptime.
    private static let pendingCeiling = 64

    private let guarded: Mutex<State> = .init(State())

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

            // Pruned to the registry's contents; clearing outright drops live hosts' identity.
            let alive = Set(hosts.tracked.map { ObjectIdentifier($0.object) })
            guarded.withLock { state in
                state.identifiers = state.identifiers.filter { alive.contains($0.key) }
                state.identifiers[ObjectIdentifier(controller)] = instance
            }
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
        guarded.withLock { $0 = State() }
    }

    #if canImport(UIKit)
    private func loaded(_ receiver: AnyObject, _ context: Context) {
        guard SwiftUIHost.kind(of: receiver) != nil else {
            return
        }

        let loadedAt = context.clock.now().nanoseconds
        guarded.withLock { state in
            if state.loadedAt.count >= Self.pendingCeiling {
                state.loadedAt.removeAll()
            }

            state.loadedAt[ObjectIdentifier(receiver)] = loadedAt
        }
    }

    private func appeared(_ receiver: AnyObject, _ context: Context) {
        guard let kind = SwiftUIHost.kind(of: receiver),
              let controller = receiver as? UIViewController
        else {
            return
        }

        hosts.add(controller)

        let key = ObjectIdentifier(receiver)
        let (loaded, instance) = guarded.withLock { state in
            (state.loadedAt.removeValue(forKey: key), state.identifiers[key])
        }

        let root = SwiftUIHost.rootView(of: receiver)

        context.emit { out in
            out.put(.hostKind(kind.rawValue))
            out.put(.hostRootViewType(root.name))
            out.put(.hostRootViewOpaque(root.isOpaque))
            out.put(.viewControllerClass(String(describing: type(of: receiver))))
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

/// Hosting-view layout timing — hook only counts; more induces AttributeGraph cycles.
final class HostUpdates: Streamable, PlainInstrument, @unchecked Sendable {
    private struct Hooked {
        var classes: Set<ObjectIdentifier> = []
        var lastName: String?
    }

    static let id: InstrumentID = .swiftUIHostUpdates
    static let entity = Entity.ID.swiftUIHost

    private static let passes: TallySlot = .first
    private static let totalNanoseconds: TallySlot = .second
    private static let peakNanoseconds: TallySlot = .third

    private let hooked: Mutex<Hooked> = .init(Hooked())

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

        // A request arriving after the screen did counts nothing until it's revisited.
        DispatchQueue.main.async { [weak self] in
            guard context.isActive else {
                return
            }

            SwiftUIHost.onScreen().forEach { self?.appeared($0, context) }
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
            let name = hooked.withLock { $0.lastName }
            if let name {
                out.put(.hostViewClass(name))
            }
        }
        #endif
    }

    func stopObserving() {
        hooked.withLock { $0 = Hooked() }
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
        let name = NSStringFromClass(hostingView)
        let alreadyHooked = hooked.withLock { hooked -> Bool in
            let already = hooked.classes.contains(key)
            if !already {
                hooked.classes.insert(key)
                hooked.lastName = name
            }

            return already
        }
        guard !alreadyHooked else {
            return
        }

        // Off this call stack — re-enters the swizzle lock from inside a running hook.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let installed = context.installIfActive {
                self.hookLayout(of: hostingView, context)
            }
            guard !installed else {
                return
            }

            // Request ended before install — un-record so a later request can hook again.
            self.forget(key)
        }
    }

    private func forget(_ key: ObjectIdentifier) {
        hooked.withLock { $0.classes.remove(key) }
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

/// Sheets and modal screens presenting and dismissing, seen through the UIKit underneath.
final class Presentation: Streamable, PlainInstrument {
    static let id: InstrumentID = .swiftUIPresentation
    static let entity = Entity.ID.swiftUIPresentation

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

        // Presented only, not pushed — navigation arrivals belong to swiftui.host.appear.
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

/// Log records reduced to "this rule broke, this many times" rather than one per occurrence.
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
    /// Distinct subjects the ceiling left out — "sixteen kinds" and "sixteen of many" differ.
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

        // By count then message — ordering on arrival would make two captures disagree.
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

    /// By level, not a category deny-list — `_logChanges()` logs at `.info`, so it's named.
    static func admits(_ record: LogRecord) -> Bool {
        switch record.subsystem {
        case "com.apple.runtime-issues": true
        case "com.apple.SwiftUI": admittedSwiftUICategories.contains(record.category)
        default: record.level.isDiagnostic
        }
    }
}

/// SwiftUI's undefined-behaviour faults, logged with or without a debugger attached.
final class RuntimeIssues: Streamable, PlainInstrument {
    static let id: InstrumentID = .swiftUIRuntimeIssues
    static let entity = Entity.ID.swiftUIRuntimeIssue

    /// `attributegraph` is the survivable half of the family that otherwise aborts.
    private static let subsystems = [
        "com.apple.runtime-issues",
        "com.apple.attributegraph",
        "com.apple.SwiftUI",
    ]
    /// Describes a burst, not a transcript — avoids spending the budget on repeats.
    private static let subjectsPerFlush = 16

    private let reader: LogStoreReader = .init(subsystems: RuntimeIssues.subsystems)

    init() {}

    /// On every row, not only the first — a sibling count needs it to divide by.
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
            out.also(Entity.ID.swiftUIRuntimeIssue) { sibling in
                put(subject, over: window, into: &sibling)
            }
        }
        guard digest.omitted > 0 else {
            return
        }

        out.also(Entity.ID.swiftUIRuntimeIssue) { sibling in
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
        // 15s: an OSLogStore drain measured ~10s on device regardless of what's read.
        context.flush(every: .seconds(15)) { [reader] out, window in
            switch reader.drain() {
            case .unavailable(let reason):
                out.put(.windowNanoseconds(window.nanoseconds))
                out.put(.mechanismStatus("unavailable: \(reason)"))
            case .read(let records, _):
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

/// Recognises hosts by class name — unrecognised ones report `.unknown`, never skipped.
enum SwiftUIHost {
    enum Kind: String {
        case hostingController
        case navigationStack
        case presentation
        case unknown
    }

    struct RootView {
        let name: String
        /// True when the type erased itself (`AnyView`) before a real name could be read.
        let isOpaque: Bool
    }

    /// Presentation wrappers, not the view — unwrapped toward the developer's name.
    private static let transparentWrappers: Set<String> = [
        "ModifiedContent",
        "LazyView",
        "ParameterizedLazyView",
        "_ViewModifier_Content",
        "EnvironmentKeyWritingModifier",
    ]

    static func kind(of object: AnyObject) -> Kind? {
        kind(fromDescription: String(describing: type(of: object)))
    }

    #if canImport(UIKit)
    /// Hosts already on screen — foreground-active, visible windows only, main thread only.
    static func onScreen() -> [UIViewController] {
        guard let application = HostApplication.shared else {
            return []
        }

        var found = [UIViewController]()
        var pending = application
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0 }
            .compactMap(\.rootViewController)

        while let controller = pending.popLast() {
            if kind(of: controller) != nil {
                found.append(controller)
            }

            pending.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController {
                pending.append(presented)
            }
        }

        return found
    }
    #endif

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

    /// Strips the outer wrapper and unwraps modifiers until a real name survives.
    static func rootView(of object: AnyObject) -> RootView {
        rootView(fromDescription: String(describing: type(of: object)))
    }

    static func rootView(fromDescription description: String) -> RootView {
        guard var current = firstGenericArgument(of: description) else {
            return RootView(name: description, isOpaque: true)
        }

        // Bounded — the type name is from a framework and could take any shape.
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

    /// Generic arguments, nesting-aware — a regex over `<…>` splits nested generics wrong.
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
    /// Read off a live instance so no private class name is written into the binary.
    static func hostingViewClass(of controller: UIViewController) -> AnyClass? {
        guard let view = controller.viewIfLoaded else {
            return nil
        }

        return object_getClass(view)
    }
    #endif
}

/// Reads render state via `Mirror` — `object_getIvar` rejected the whole graph on device.
enum SwiftUIReflection {
    enum Reach {
        case reached(Any, generation: String)
        case pathDeadEnded(generation: String, atStep: String)
        case noHostingView
    }

    struct DisplayListShape {
        let itemCount: Int
        /// `ViewUpdater.seed`, advanced once per SwiftUI update — the direct answer.
        let seed: UInt32?
        /// Fallback for when no seed is found: a hash of each item's identity and version.
        let fingerprint: Int
    }

    /// Tried newest-first: the object says which path works, not the OS version.
    static let rendererPaths: [(generation: String, path: [String])] = [
        ("26", ["_base", "viewGraph", "renderer"]),
        ("18.1", ["_base", "renderer"]),
        ("18.0", ["renderer"]),
    ]

    /// Nil until the view enters a window — the walk keeps going rather than stop there.
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

    /// Unwraps `Optional`, which `Mirror` otherwise reports as its own one-child structure.
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

    /// Requires `lastList` exactly, not any collection called `items`.
    static func displayList(in renderer: Any, depth: Int = 0) -> DisplayListShape? {
        guard depth < 6 else {
            return nil
        }

        let mirror = Mirror(reflecting: renderer)

        // Reads the matched object, not just the list — the seed sits on the updater.
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

    /// Widened from `UInt16`: 16 bits wrap in an afternoon of updates.
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

    /// Read by name, skipped when absent — an unfamiliar item shape doesn't break the walk.
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
