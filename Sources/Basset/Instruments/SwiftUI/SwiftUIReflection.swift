import Foundation

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
