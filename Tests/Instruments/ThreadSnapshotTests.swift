@testable import Basset
import BassetECS
import Foundation
import Testing

/// `emptyOnlyBecauseTheProcessIsCrowded` asserts the ceiling was crossed, so a broken walk fails.
@Suite(
    .serialized,
    .disabled(
        if: ThreadWalker.isThreadSanitizerLoaded,
        "the walker refuses to suspend threads while a sanitizer is loaded"
    )
)
struct ThreadWalkerTests {
    /// The process has to survive being suspended by its own diagnostic tool.
    @Test func walkingSuspendsAndResumesWithoutStoppingTheProcess() {
        MainThreadPort.capture()
        let walker = ThreadWalker()

        let stacks = walker.walk()
        let survived = (1...1000).reduce(0, +)

        #expect(
            survived == 500500,
            "the process still runs after every thread was suspended"
        )
        guard !emptyOnlyBecauseTheProcessIsCrowded(stacks) else {
            return
        }

        #expect(!stacks.isEmpty)
    }

    @Test func walkingRepeatedlyStaysStable() {
        let walker = ThreadWalker()

        for _ in 0 ..< 20 {
            _ = walker.walk()
        }

        let stacks = walker.walk()
        guard !emptyOnlyBecauseTheProcessIsCrowded(stacks) else {
            return
        }

        #expect(stacks.isEmpty == false)
    }

    @Test func aWalkedThreadHasFramesAndTheWalkerIsNotAmongThem() {
        MainThreadPort.capture()
        let walker = ThreadWalker()

        let stacks = walker.walk()
        guard !emptyOnlyBecauseTheProcessIsCrowded(stacks) else {
            return
        }

        #expect(stacks.contains { !$0.frames.isEmpty }, "some thread reported a stack")
        #expect(
            stacks.allSatisfy { $0.frames.count <= ThreadWalker.maxFrames },
            "no stack runs past the frame cap"
        )
    }

    /// On the main actor — off it, `capture()` only queues the read, racing the walk it sets up.
    @Test func theMainThreadIsMarked() async {
        await MainActor.run { MainThreadPort.capture() }
        let walker = ThreadWalker()

        let stacks = await Task.detached { walker.walk() }.value
        #expect(MainThreadPort.port != 0)
        guard !emptyOnlyBecauseTheProcessIsCrowded(stacks) else {
            return
        }

        #expect(stacks.filter(\.isMain).count == 1, "exactly one thread is the main one")
    }

    /// Without the process-wide lock, each walk suspends the other's thread and neither resumes.
    @Test func concurrentWalksDoNotSuspendEachOther() async {
        await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { ThreadWalker().walk().count }
            }
            var completed = 0
            for await _ in group {
                completed += 1
            }
            #expect(completed == 8, "every concurrent walk finished")
        }
    }

    /// Fails the calling test when an empty walk isn't explained by the machine, not a bare return.
    private func emptyOnlyBecauseTheProcessIsCrowded(
        _ stacks: [ThreadStack],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        guard stacks.isEmpty else {
            return false
        }

        let live = ThreadWalker.liveThreadCount()
        #expect(
            (live ?? 0) > ThreadWalker.maxThreads,
            """
            the walk returned nothing while the process held \
            \(live.map(String.init) ?? "an unreadable number of") threads, which \
            is not past the \(ThreadWalker.maxThreads) it refuses at — so the \
            walker stopped working rather than the machine being busy
            """,
            sourceLocation: sourceLocation
        )
        return true
    }
}

/// An empty walk used to produce no reading, indistinguishable from a fault that never fired.
struct ThreadSnapshotRefusalTests {
    @Test func aProcessOverTheCeilingSaysHowFarOver() {
        let said = ThreadSnapshot.refusal(
            liveThreads: ThreadWalker.maxThreads + 130,
            sanitizerLoaded: false
        )

        #expect(said.contains("\(ThreadWalker.maxThreads + 130) threads"))
        #expect(said.contains("\(ThreadWalker.maxThreads)"))
    }

    @Test func aProcessUnderTheCeilingBlamesTheWalkRatherThanTheCount() {
        let said = ThreadSnapshot.refusal(liveThreads: 4, sanitizerLoaded: false)

        #expect(said == "unavailable: the walk reported no threads")
    }

    @Test func anUnreadableThreadListIsItsOwnAnswer() {
        let said = ThreadSnapshot.refusal(liveThreads: nil, sanitizerLoaded: false)

        #expect(said == "unavailable: the thread list could not be read")
    }

    @Test func theCeilingItselfIsNotOverIt() {
        #expect(
            ThreadSnapshot.refusal(
                liveThreads: ThreadWalker.maxThreads,
                sanitizerLoaded: false
            ) == "unavailable: the walk reported no threads",
            "the walk admits a process at the ceiling, so the count is not the reason"
        )
    }

    /// The sanitizer is why the walk refused, so no thread count may overrule it.
    @Test func aLoadedSanitizerIsTheReasonWhateverTheCountSays() {
        for liveThreads in [nil, 4, ThreadWalker.maxThreads + 130] {
            #expect(
                ThreadSnapshot.refusal(liveThreads: liveThreads, sanitizerLoaded: true)
                    == "unavailable: a thread sanitizer is loaded"
            )
        }
    }
}

/// Sanitizers lock inside the suspended window, so the walker refuses rather than deadlocks.
@Suite(.enabled(
    if: ThreadWalker.isThreadSanitizerLoaded,
    "the refusal only exists while a sanitizer is loaded"
))
struct SanitizedWalkTests {
    @Test func aWalkRefusesRatherThanSuspending() {
        MainThreadPort.capture()

        #expect(ThreadWalker().walk().isEmpty)
    }

    @Test func aMainThreadSampleRefusesRatherThanSuspending() async {
        await MainActor.run { MainThreadPort.capture() }
        let walker = ThreadWalker()

        let frames = await Task.detached { walker.walkMainThread() }.value

        #expect(frames == nil)
    }
}

/// Shares `ThreadWalkerTests`'s reason for serializing: each fault suspends every thread.
@Suite(
    .serialized,
    .disabled(
        if: ThreadWalker.isThreadSanitizerLoaded,
        "the walker refuses to suspend threads while a sanitizer is loaded"
    )
)
struct ThreadSnapshotFaultTests {
    /// A binary already reported by this instrument owes nothing new on a later fault,
    /// even though a later walk can legitimately touch threads the first one didn't.
    @Test func anImageAlreadyReportedByThisInstrumentIsNotReportedAgain() {
        MainThreadPort.capture()
        let instrument = ThreadSnapshot()

        var first = Readings(
            entity: ThreadSnapshot.entity,
            instrumentName: "runtime.threadSnapshot"
        )
        instrument.fault(.hang, &first)
        let firstImages = imageUUIDs(in: first)
        guard !firstImages.isEmpty else {
            return
        }

        var second = Readings(
            entity: ThreadSnapshot.entity,
            instrumentName: "runtime.threadSnapshot"
        )
        instrument.fault(.hang, &second)

        #expect(firstImages.isDisjoint(with: imageUUIDs(in: second)))
    }

    private func imageUUIDs(in readings: Readings) -> Set<String> {
        Set(
            readings.sealedSiblings()
                .filter { $0.id == .binaryImage }
                .compactMap { entity in
                    entity.components.first { $0.id == .imageUUID }?.value.rendered
                }
        )
    }
}

struct BinaryImageTests {
    @Test func theMainExecutableNamesItsBuildAndWhereItLanded() throws {
        let executable = try #require(BinaryImages.mainExecutable())

        #expect(
            executable.uuid.count == 36,
            "a rendered UUID, which is what a dSYM is found by"
        )
        #expect(executable.loadAddress > 0)
        #expect(executable.size > 0)
    }

    @Test func everyLoadedImageCarriesAUUID() {
        let images = BinaryImages.loaded()

        #expect(images.count > 1)
        #expect(images.allSatisfy { !$0.uuid.isEmpty })
    }

    @Test func anImageContainsItsOwnAddressesAndNotThoseBelowIt() {
        let images = BinaryImages.loaded()
        guard let image = images.first(where: { $0.size > 0 }) else {
            return
        }

        #expect(image.contains(image.loadAddress))
        #expect(image.contains(image.loadAddress + image.size - 1))
        #expect(image.contains(image.loadAddress + image.size) == false)
    }
}

struct ReadingsSiblingTests {
    @Test func aSiblingIsItsOwnEntityAndDoesNotTouchTheFirst() {
        var out = readings()
        out.put(.threadIndex(0))
        out.also(.binaryImage) { image in image.put(.imageName("Basset")) }

        #expect(out.sealed().id == .thread)
        #expect(out.sealed().components.count == 1)
        #expect(out.sealedSiblings().map(\.id) == [.binaryImage])
    }

    @Test func anEmptySiblingIsNotEmitted() {
        var out = readings()
        out.put(.threadIndex(0))
        out.also(.binaryImage) { _ in }

        #expect(out.sealedSiblings().isEmpty)
    }

    @Test func repeatedComponentsKeepTheirOrderSoAStackNeedsNoIndices() {
        var out = readings()
        out.put(.frameAddress(0x1000))
        out.put(.frameAddress(0x2000))
        out.put(.frameAddress(0x3000))

        #expect(
            out.sealed().components.map(\.value) == [
                .uint64(0x1000), .uint64(0x2000), .uint64(0x3000),
            ]
        )
    }

    private func readings(_ entity: Entity.ID = .thread) -> Readings {
        Readings(
            entity: entity,
            instrumentName: "runtime.threadSnapshot"
        )
    }
}
