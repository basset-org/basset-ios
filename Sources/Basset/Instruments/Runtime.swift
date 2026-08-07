import BassetECS
import Foundation

/// Every thread's stack, as raw return addresses, taken when something has
/// already gone wrong.
///
/// **Faults only.** Conforming to `SnapshotInstrument` as well makes the runner
/// take a full walk the moment the instrument activates — a process-wide suspend
/// nobody asked for, at a moment nothing is wrong, and worst of all under an
/// `at_launch` request, which activates from persisted state during launch.
///
/// Nothing here decides *when*: a hang is not this instrument's concern and it
/// does not know one exists. It answers whatever fault the runner hands it.
///
/// The on-demand question — what threads exist, what they are named, what they
/// cost — is `concurrency.threadInventory`, which answers from `task_threads` and
/// `thread_info` without suspending anything. Same subject, different price, and
/// the two stay separate so a request can name the one it wants.
final class ThreadSnapshot: FaultInstrument {
    static let id: InstrumentID = .threadSnapshot
    static let entity = Entity.ID.thread

    private let walker: ThreadWalker = .init()

    init() {
        // Asked for while the main thread still answers, because the capture
        // that needs it happens when it has stopped.
        MainThreadPort.capture()
    }

    func fault(_ kind: FaultKind, _ out: inout Readings) {
        take(into: &out)
    }

    /// The first thread fills the readings the caller already holds; the rest,
    /// and the images their addresses land in, are separate entities. A stack
    /// per thread rather than one entity holding all of them, so a reader can
    /// take one thread without decoding the others.
    private func take(into out: inout Readings) {
        let stacks = walker.walk()
        guard let first = stacks.first else {
            return
        }

        describe(first, into: &out)
        for stack in stacks.dropFirst() {
            out.also(Self.entity) { thread in describe(stack, into: &thread) }
        }
        for image in images(covering: stacks) {
            out.also(.binaryImage) { entry in
                entry.put(.imageName(image.name))
                entry.put(.imageLoadAddress(image.loadAddress))
                entry.put(.imageUUID(image.uuid))
            }
        }
    }

    private func describe(_ stack: ThreadStack, into out: inout Readings) {
        out.put(.threadIndex(UInt32(stack.index)))
        out.put(.threadName(stack.name))
        out.put(.threadIsMain(stack.isMain))
        // Repeated, innermost first: the order the components arrive in is the
        // order of the stack, so nothing has to number the frames.
        for frame in stack.frames {
            out.put(.frameAddress(frame))
        }
    }

    /// Only the images an address actually landed in. A process maps several
    /// hundred; a stack touches a handful, and the rest would be the largest
    /// part of the capture while symbolicating nothing.
    private func images(covering stacks: [ThreadStack]) -> [BinaryImage] {
        let loaded = BinaryImages.loaded()
        var covering = [String: BinaryImage]()
        for stack in stacks {
            for frame in stack.frames {
                guard let image = loaded.first(where: { $0.contains(frame) })
                else {
                    continue
                }

                covering[image.uuid] = image
            }
        }
        return covering.values.sorted { $0.loadAddress < $1.loadAddress }
    }
}
