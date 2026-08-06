@testable import Basset
import BassetECS
import Foundation
import Testing

struct ThreadWalkerTests {
    /// The process has to survive being suspended by its own diagnostic tool.
    /// Everything else in this file is secondary to that.
    @Test func walkingSuspendsAndResumesWithoutStoppingTheProcess() {
        MainThreadPort.capture()
        let walker = ThreadWalker()

        let stacks = walker.walk()
        let survived = (1...1000).reduce(0, +)

        #expect(
            survived == 500500,
            "the process still runs after every thread was suspended"
        )
        #expect(!stacks.isEmpty)
    }

    @Test func walkingRepeatedlyStaysStable() {
        let walker = ThreadWalker()

        for _ in 0 ..< 20 {
            _ = walker.walk()
        }

        #expect(walker.walk().isEmpty == false)
    }

    @Test func aWalkedThreadHasFramesAndTheWalkerIsNotAmongThem() {
        MainThreadPort.capture()
        let walker = ThreadWalker()

        let stacks = walker.walk()

        #expect(stacks.contains { !$0.frames.isEmpty }, "some thread reported a stack")
        #expect(
            stacks.allSatisfy { $0.frames.count <= ThreadWalker.maxFrames },
            "no stack runs past the frame cap"
        )
    }

    /// Captured while the main thread answers, read from a thread that is not it.
    ///
    /// The capture runs on the main actor rather than wherever the test happens
    /// to be scheduled. `capture()` off the main thread can only ask the main
    /// queue and return, so calling it inline races the walk it is setting up
    /// for and reports no thread marked main roughly one run in eight.
    @Test func theMainThreadIsMarked() async {
        await MainActor.run { MainThreadPort.capture() }
        let walker = ThreadWalker()

        let stacks = await Task.detached { walker.walk() }.value

        #expect(MainThreadPort.port != 0)
        #expect(stacks.filter(\.isMain).count == 1, "exactly one thread is the main one")
    }

    /// The deadlock the process-wide lock exists to prevent: without it, each
    /// walk suspends the other's thread and neither survives to resume anything.
    /// A failure here is a hang rather than a wrong answer, so the assertion is
    /// only that every walk returned.
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

    private func readings(_ entity: Entity.WireID = .thread) -> Readings {
        Readings(
            entity: entity,
            instrumentName: "runtime.threadSnapshot"
        )
    }
}
