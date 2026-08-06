import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
