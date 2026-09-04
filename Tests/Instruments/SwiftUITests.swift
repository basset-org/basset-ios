@testable import Basset
import Foundation
import Testing

/// Pure logic, so it runs in `bazel test //...` rather than behind a simulator boot.
struct SwiftUIHostTests {
    @Test func recognisesTheThreeHostingClasses() {
        #expect(SwiftUIHost
            .kind(fromDescription: "UIHostingController<ContentView>") ==
            .hostingController)
        #expect(
            SwiftUIHost.kind(fromDescription: "NavigationStackHostingController<AnyView>")
                == .navigationStack
        )
        #expect(
            SwiftUIHost.kind(fromDescription: "PresentationHostingController<SheetView>")
                == .presentation
        )
    }

    /// A hosting class nobody anticipated is still a hosting class.
    @Test func failsOpenOnAnUnknownHostingClass() {
        #expect(SwiftUIHost
            .kind(fromDescription: "TabHostingController<Root>") == .unknown)
    }

    @Test func ignoresOrdinaryViewControllers() {
        #expect(SwiftUIHost.kind(fromDescription: "CartViewController") == nil)
        #expect(SwiftUIHost.kind(fromDescription: "UINavigationController") == nil)
    }

    @Test func readsTheDevelopersOwnTypeName() {
        let root = SwiftUIHost
            .rootView(fromDescription: "UIHostingController<ContentView>")

        #expect(root.name == "ContentView")
        #expect(root.isOpaque == false)
    }

    /// The shape that actually arrives: a modifier wraps the view worth reporting.
    @Test func unwrapsModifiersToReachTheView() {
        let root = SwiftUIHost.rootView(
            fromDescription:
            "UIHostingController<ModifiedContent<CartView, _EnvironmentKeyWritingModifier<Int>>>"
        )

        #expect(root.name == "CartView")
        #expect(root.isOpaque == false)
    }

    @Test func unwrapsSeveralLayersOfModifier() {
        let root = SwiftUIHost.rootView(
            fromDescription: """
            UIHostingController<ModifiedContent<ModifiedContent<ProfileView, A>, B>>
            """
        )

        #expect(root.name == "ProfileView")
    }

    /// `AnyView` is reported, never dropped — omitting it reads as a screen that never appeared.
    @Test func marksAnErasedTypeRatherThanDroppingIt() {
        let root = SwiftUIHost.rootView(fromDescription: "UIHostingController<AnyView>")

        #expect(root.name == "AnyView")
        #expect(root.isOpaque)
    }

    @Test func marksAnErasedTypeFoundUnderAModifier() {
        let root = SwiftUIHost.rootView(
            fromDescription: "NavigationStackHostingController<ModifiedContent<AnyView, Padding>>"
        )

        #expect(root.name == "AnyView")
        #expect(root.isOpaque)
    }

    /// A regular expression over `<…>` splits this wrong; the parser tracks depth instead.
    @Test func respectsNestingWhenSplittingGenericArguments() {
        let (base, arguments) = SwiftUIHost.split("ModifiedContent<Foo<A, B>, C>")

        #expect(base == "ModifiedContent")
        #expect(arguments == ["Foo<A, B>", "C"])
    }

    @Test func handlesATypeWithNoGenericArgumentsAtAll() {
        let (base, arguments) = SwiftUIHost.split("ContentView")

        #expect(base == "ContentView")
        #expect(arguments.isEmpty)
    }

    /// The input is a framework's type name — an unbounded loop over one can hang.
    @Test func terminatesOnADeeplyNestedChain() {
        let deep = String(repeating: "ModifiedContent<", count: 40)
            + "LeafView" + String(repeating: ", M>", count: 40)
        let root = SwiftUIHost.rootView(fromDescription: "UIHostingController<\(deep)>")

        #expect(root.isOpaque)
    }
}

struct RuntimeIssueDigestTests {
    /// A storm is one finding with a count, not thousands of readings.
    @Test func collapsesARepeatedViolationIntoACount() {
        let records = Array(
            repeating: record("Modifying state during view update"),
            count: 500
        )

        let digest = RuntimeIssueDigest(records, ceiling: 16)

        #expect(digest.subjects.count == 1)
        #expect(digest.subjects.first?.count == 500)
        #expect(digest.omitted == 0)
    }

    @Test func ranksTheLoudestViolationFirst() {
        let records =
            Array(repeating: record("quiet"), count: 2)
                + Array(repeating: record("loud"), count: 40)

        let digest = RuntimeIssueDigest(records, ceiling: 16)

        #expect(digest.subjects.first?.message == "loud")
        #expect(digest.subjects.last?.message == "quiet")
    }

    /// A silent truncation would read as a complete list of what went wrong.
    @Test func reportsWhatTheCeilingLeftOut() {
        let records = (0 ..< 50).map { record("violation \($0)") }

        let digest = RuntimeIssueDigest(records, ceiling: 16)

        #expect(digest.subjects.count == 16)
        #expect(digest.omitted == 34)
    }

    /// `runtime-issues` exists only to carry violations, so its level is not consulted.
    @Test func admitsEverythingFromTheRuntimeIssuesSubsystem() {
        #expect(
            RuntimeIssueDigest.admits(
                record("x", subsystem: "com.apple.runtime-issues", level: .notice)
            )
        )
    }

    /// Severity separates precondition failures from AttributeGraph's chatter, no deny-list needed.
    @Test func admitsOnlyDiagnosticSeverityFromAttributeGraph() {
        let noise = record(
            "ignoring retroactive Equatable conformance on type __C.AGAttribute",
            subsystem: "com.apple.attributegraph",
            category: "misc",
            level: .notice
        )
        let failure = record(
            "precondition failure: attribute failed to set an initial value",
            subsystem: "com.apple.attributegraph",
            category: "misc",
            level: .fault
        )

        #expect(RuntimeIssueDigest.admits(noise) == false)
        #expect(RuntimeIssueDigest.admits(failure))
    }

    /// `_logChanges()` emits at `.info`, below the bar, so this category is admitted by name.
    @Test func admitsOnlyOneCategoryOfOrdinarySwiftUILogging() {
        let chatter = record("…", subsystem: "com.apple.SwiftUI", category: "Navigation")
        let changes = record(
            "Watched: _model changed.",
            subsystem: "com.apple.SwiftUI",
            category: "Changed Body Properties",
            level: .info
        )

        #expect(RuntimeIssueDigest.admits(chatter) == false)
        #expect(RuntimeIssueDigest.admits(changes))
    }

    @Test func filtersBeforeCounting() {
        let records = [record(
            "…",
            subsystem: "com.apple.SwiftUI",
            category: "Navigation"
        )]

        #expect(RuntimeIssueDigest(records, ceiling: 16).isEmpty)
    }

    private func record(
        _ message: String,
        subsystem: String = "com.apple.runtime-issues",
        category: String = "SwiftUI",
        level: LogRecord.Level = .fault
    ) -> LogRecord {
        LogRecord(
            subsystem: subsystem,
            category: category,
            message: message,
            level: level,
            date: Date()
        )
    }
}

/// `Stored` is a Swift struct on purpose — reading one as an object is undefined behavior.
private struct Stored {
    let count: Int
}

private struct FakeItem {
    let identity: FakeValue
    let version: FakeValue
}

private struct FakeValue {
    let value: UInt32
}

private struct FakeList {
    let items: [FakeItem]
}

private struct FakeSeed {
    let value: UInt16
}

/// Shaped after a real device: a view updater carrying `lastList` beside a `seed` SwiftUI advances.
private final class Renderer {
    let lastList: FakeList?
    let seed: FakeSeed

    init(identities: [UInt32] = [1, 2, 3], seed: UInt16 = 1429) {
        lastList = FakeList(
            items: identities.map {
                FakeItem(identity: FakeValue(value: $0), version: FakeValue(value: $0))
            }
        )
        self.seed = FakeSeed(value: seed)
    }
}

/// A renderer whose updater carries no seed — the shape the fingerprint exists for.
private final class SeedlessRenderer {
    let lastList: FakeList?

    init(identities: [UInt32] = [1, 2, 3]) {
        lastList = FakeList(
            items: identities.map {
                FakeItem(identity: FakeValue(value: $0), version: FakeValue(value: $0))
            }
        )
    }
}

private final class ViewGraph {
    let renderer: Renderer? = Renderer()
}

private final class Base {
    let viewGraph: ViewGraph? = ViewGraph()
}

private final class Host {
    let _base: Base? = Base()
    let stored: Stored = .init(count: 7)
}

private final class Bare {
    let unrelated = 1
}

/// Holds an `items` collection that is not the display list — once mistaken for it.
private final class Decoy {
    let state: DecoyState = .init()
}

private struct DecoyState {
    let items: [Int] = [1]
}

struct SwiftUIReflectionTests {
    @Test func readsAStoredPropertyByName() {
        #expect(SwiftUIReflection.child(
            of: FakeValue(value: 9),
            named: "value"
        ) as? UInt32 == 9)
    }

    /// Every step of the real renderer path is an optional.
    @Test func unwrapsOptionalsAlongThePath() {
        let base = SwiftUIReflection.child(of: Host(), named: "_base")

        #expect(base is Base)
    }

    @Test func returnsNilForAPropertyThatDoesNotExist() {
        #expect(SwiftUIReflection.child(of: Bare(), named: "viewGraph") == nil)
    }

    /// Swift stored properties carry no ObjC type encoding, which `ivar_getTypeEncoding` misread.
    @Test func seesASwiftStructProperty() {
        let stored = SwiftUIReflection.child(of: Host(), named: "stored")

        #expect(stored is Stored)
    }

    @Test func walksTheWholeRendererPath() {
        switch SwiftUIReflection.renderer(of: Host()) {
        case .reached(let renderer, let generation):
            #expect(renderer is Renderer)
            #expect(generation == "26")
        default:
            Issue
                .record(
                    "_base.viewGraph.renderer is the generation-26 path and it is present"
                )
        }
    }

    /// A dead end is reported as one, not an empty reading that looks like calm.
    @Test func reportsWhichStepOfWhichPathDeadEnded() {
        switch SwiftUIReflection.renderer(of: Bare()) {
        case .pathDeadEnded(let generation, let step):
            #expect(generation == "26")
            #expect(step == "_base")
        default:
            Issue.record("a subject with no renderer must report a dead end")
        }
    }

    @Test func reportsAMissingHostingViewSeparately() {
        guard case .noHostingView = SwiftUIReflection.renderer(of: nil) else {
            Issue
                .record(
                    "no view loaded is a different answer from an unreachable renderer"
                )
            return
        }
    }

    @Test func readsTheDisplayListShapeOnceTheRendererIsReached() {
        let shape = SwiftUIReflection.displayList(in: Renderer())

        #expect(shape?.itemCount == 3)
        #expect(shape?.seed == 1429)
    }

    /// The seed sits on the view updater, not on the list it points at.
    @Test func readsTheSeedFromTheUpdaterBesideTheList() {
        #expect(SwiftUIReflection.displayList(in: Renderer(seed: 77))?.seed == 77)
    }

    /// A loose search for `items` once matched something that wasn't the display list.
    @Test func refusesACollectionThatIsNotUnderLastList() {
        #expect(SwiftUIReflection.displayList(in: Decoy()) == nil)
    }

    /// Item count doesn't move when a re-render changes content without changing structure.
    @Test func fingerprintsWhatTheItemsSayNotHowManyThereAre() {
        let before = SwiftUIReflection.displayList(in: SeedlessRenderer(identities: [1, 2, 3]))
        let after = SwiftUIReflection.displayList(in: SeedlessRenderer(identities: [1, 2, 9]))

        #expect(before?.itemCount == after?.itemCount)
        #expect(before?.fingerprint != nil)
        #expect(before?.fingerprint != after?.fingerprint)
    }

    @Test func fingerprintIsStableForAnUnchangedList() {
        let first = SwiftUIReflection.displayList(in: SeedlessRenderer())
        let second = SwiftUIReflection.displayList(in: SeedlessRenderer())

        #expect(first?.fingerprint == second?.fingerprint)
    }

    /// The seed is the answer; walking every item for a hash on top of it was the cost.
    @Test func skipsTheItemWalkWhenTheSeedAnswers() {
        let shape = SwiftUIReflection.displayList(in: Renderer(identities: [1, 2, 3]))

        #expect(shape?.seed == 1429)
        #expect(shape?.itemCount == 3)
        #expect(shape?.fingerprint == nil)
    }

    /// Newest first, so an OS this table has never seen is still tried, not assumed unreachable.
    @Test func triesTheNewestPathFirst() {
        #expect(SwiftUIReflection.rendererPaths.map(\.generation) == [
            "26",
            "18.1",
            "18.0",
        ])
        #expect(SwiftUIReflection.rendererPaths.first?.path == [
            "_base",
            "viewGraph",
            "renderer",
        ])
    }
}
