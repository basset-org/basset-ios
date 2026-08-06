@testable import Basset
import Foundation
import Testing

/// The parts of the `swiftui` domain that are pure logic: recognising a host,
/// recovering the developer's own type name from the generic parameter, and
/// reducing a burst of log records to what it says. All host-runnable, so they
/// land in `bazel test //...` rather than behind a simulator boot.
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

    /// The rule that keeps a rename from silencing the domain. A hosting class
    /// nobody anticipated is still a hosting class.
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

    /// The shape that actually arrives: a modifier wraps the view, and the name
    /// worth reporting is inside it.
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

    /// `AnyView` is reported, never dropped: in a capture, a screen that was
    /// omitted and a screen that never appeared are the same absence.
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

    /// A regular expression over `<…>` splits this in the wrong place, which is
    /// why the parser tracks depth.
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

    /// An unwrappable chain must terminate. The input is a framework's type name
    /// and an unbounded loop over one is a hang waiting for an unfamiliar shape.
    @Test func terminatesOnADeeplyNestedChain() {
        let deep = String(repeating: "ModifiedContent<", count: 40)
            + "LeafView" + String(repeating: ", M>", count: 40)
        let root = SwiftUIHost.rootView(fromDescription: "UIHostingController<\(deep)>")

        #expect(root.isOpaque)
    }
}

struct RuntimeIssueDigestTests {
    /// The point of the instrument: a storm is one finding with a count, not
    /// thousands of readings.
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

    /// A dropped violation is reported. A capture that silently truncated would
    /// read as a complete list of what went wrong.
    @Test func reportsWhatTheCeilingLeftOut() {
        let records = (0 ..< 50).map { record("violation \($0)") }

        let digest = RuntimeIssueDigest(records, ceiling: 16)

        #expect(digest.subjects.count == 16)
        #expect(digest.omitted == 34)
    }

    /// `runtime-issues` exists only to carry violations, so its level is not
    /// consulted.
    @Test func admitsEverythingFromTheRuntimeIssuesSubsystem() {
        #expect(
            RuntimeIssueDigest.admits(
                record("x", subsystem: "com.apple.runtime-issues", level: .notice)
            )
        )
    }

    /// A device capture reported "ignoring retroactive Equatable conformance on
    /// type __C.AGAttribute" as a finding, because the whole subsystem was
    /// admitted. Severity separates the precondition failures worth reading from
    /// AttributeGraph's ordinary chatter without a category deny-list to keep up
    /// to date.
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

    /// Ordinary SwiftUI logging is noisy, and admitting it would let chatter
    /// spend the ceiling a fault needed.
    /// `_logChanges()` emits at `.info`, below the severity bar, so this one
    /// category is admitted by name rather than by level.
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

/// Controlled types rather than a live `_UIHostingView`: what is being tested is
/// the walk, and a framework's private shape is the thing this must not depend
/// on. `Stored` is a Swift struct on purpose — reading one of those as an object
/// is the undefined behaviour `Mirror` exists here to avoid.
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

/// Shaped after what an iPhone 16 Pro on iOS 27 actually holds: a view updater
/// carrying `lastList` beside a `seed` SwiftUI advances per update.
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

/// Holds a collection called `items` that is not a display list — the shape that
/// made the instrument claim success on device.
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

    /// A path stops at the first optional property unless reflection's own
    /// one-child wrapper is unwrapped, and every step of the real renderer path
    /// is an optional.
    @Test func unwrapsOptionalsAlongThePath() {
        let base = SwiftUIReflection.child(of: Host(), named: "_base")

        #expect(base is Base)
    }

    @Test func returnsNilForAPropertyThatDoesNotExist() {
        #expect(SwiftUIReflection.child(of: Bare(), named: "viewGraph") == nil)
    }

    /// The regression this file exists for. A device dump of `_UIHostingView` on
    /// iOS 27 came back with every ObjC type encoding empty, because Swift
    /// stored properties have none — so an `ivar_getTypeEncoding` guard rejected
    /// the whole graph and the instrument reported the renderer unreachable while
    /// `_base` was sitting right there. Reflection sees a Swift struct as a
    /// struct rather than as an absence.
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

    /// The tier-3 contract: a dead end is reported as one, so the instrument can
    /// emit "could not read" rather than an empty reading that looks like calm.
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

    /// The seed sits on the view updater, not on the list it points at, so the
    /// object that matched has to be read rather than only what it held.
    @Test func readsTheSeedFromTheUpdaterBesideTheList() {
        #expect(SwiftUIReflection.displayList(in: Renderer(seed: 77))?.seed == 77)
    }

    /// The regression from the second device run: a loose search for any
    /// collection called `items` matched something that was not the display list
    /// and reported success. Only `lastList` identifies it.
    @Test func refusesACollectionThatIsNotUnderLastList() {
        #expect(SwiftUIReflection.displayList(in: Decoy()) == nil)
    }

    /// Item count does not move when a re-render changes content without
    /// changing structure, which is most of them — so churn is detected from
    /// what the items say.
    @Test func fingerprintsWhatTheItemsSayNotHowManyThereAre() {
        let before = SwiftUIReflection.displayList(in: Renderer(identities: [1, 2, 3]))
        let after = SwiftUIReflection.displayList(in: Renderer(identities: [1, 2, 9]))

        #expect(before?.itemCount == after?.itemCount)
        #expect(before?.fingerprint != after?.fingerprint)
    }

    @Test func fingerprintIsStableForAnUnchangedList() {
        let first = SwiftUIReflection.displayList(in: Renderer())
        let second = SwiftUIReflection.displayList(in: Renderer())

        #expect(first?.fingerprint == second?.fingerprint)
    }

    /// Newest first, so an OS this table has never seen is still tried rather
    /// than assumed unreachable.
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
