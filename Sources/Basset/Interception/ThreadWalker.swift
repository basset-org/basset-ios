import Darwin
import Foundation

public struct ThreadStack: Sendable {
    public let index: Int
    public let name: String
    public let isMain: Bool
    public let frames: [UInt64]
}

/// Every thread in the process, suspended together and read as raw memory.
///
/// The rule the whole type exists to enforce: between `thread_suspend` and
/// `thread_resume`, nothing may allocate, take a lock, or send an Objective-C
/// message. A suspended thread can be holding the malloc lock or the pthread
/// list lock, and asking for either while it cannot run is a deadlock with no
/// timeout — the process simply stops, and the diagnostic tool is the reason.
///
/// So names are read *before* the suspend, frames land in a fixed buffer on the
/// walking thread's own stack, and every object here is built after everything
/// is running again.
public final class ThreadWalker: @unchecked Sendable {
    /// Beyond this, the suspension itself becomes the risk rather than the
    /// answer, and a process with this many threads has a different problem.
    public static let maxThreads = 70
    public static let maxFrames = 100

    /// Process-wide, and deliberately static rather than per-instance, for the
    /// same reason `Swizzle`'s table is: what it guards is a property of the
    /// process, not of the object holding it.
    ///
    /// **Two walks at once deadlock, and neither one is doing anything wrong.**
    /// Each suspends every thread but its own, so walk A suspends walk B's
    /// thread while B has already suspended A's — both are stopped, and the only
    /// threads that could call `thread_resume` are the two that cannot run. The
    /// process stops with no timeout. It is reachable in production, not only in
    /// a parallel test suite: `reading()` runs on the runner queue and
    /// `fault()` on the hang watchdog, and a snapshot request arriving while a
    /// hang is being reported puts both in flight at once.
    ///
    /// Waiting here is safe. A walk that suspends a thread blocked on this lock
    /// needs nothing from it and resumes it before releasing.
    private static let exclusive: NSLock = .init()

    public init() {}

    // Nothing below this line may allocate: it runs with the process suspended.

    private static func unwind(
        _ thread: thread_t,
        into buffer: UnsafeMutableBufferPointer<UInt64>
    ) -> Int {
        guard var frame = framePointer(of: thread) else {
            return 0
        }

        var taken = 0
        while taken < buffer.count, frame != 0, frame % 2 == 0 {
            // A frame is { previous frame pointer, return address }. Both come
            // through vm_read_overwrite, so a corrupt pointer ends the walk
            // instead of faulting the process.
            guard let previous = read(frame),
                  let returning = read(frame + 8)
            else {
                break
            }
            guard returning != 0 else {
                break
            }

            buffer[taken] = returning
            taken += 1
            guard previous > frame else {
                break
            }

            frame = previous
        }
        return taken
    }

    private static func read(_ address: UInt64) -> UInt64? {
        var value: UInt64 = 0
        var read = vm_size_t(0)
        let outcome = withUnsafeMutablePointer(to: &value) { slot in
            vm_read_overwrite(
                mach_task_self_,
                vm_address_t(address),
                vm_size_t(MemoryLayout<UInt64>.size),
                vm_address_t(UInt(bitPattern: slot)),
                &read
            )
        }
        guard outcome == KERN_SUCCESS, read == vm_size_t(MemoryLayout<UInt64>.size) else {
            return nil
        }

        return value
    }

    private static func framePointer(of thread: thread_t) -> UInt64? {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let read = withUnsafeMutablePointer(to: &state) { slot in
            slot.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(thread, ARM_THREAD_STATE64, raw, &count)
            }
        }
        guard read == KERN_SUCCESS else {
            return nil
        }

        // Pointer authentication signs the frame pointer on arm64e. The
        // signature lives above the address bits, and stripping it is what
        // makes the same walk work on both arm64 and arm64e.
        return UInt64(state.__fp) & 0x0000000fffffffff
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let read = withUnsafeMutablePointer(to: &state) { slot in
            slot.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { raw in
                thread_get_state(thread, x86_THREAD_STATE64, raw, &count)
            }
        }
        guard read == KERN_SUCCESS else {
            return nil
        }

        return state.__rbp
        #else
        return nil
        #endif
    }

    private static func name(of thread: thread_t) -> String {
        guard let handle = pthread_from_mach_thread_np(thread) else {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: 256)
        guard pthread_getname_np(handle, &buffer, buffer.count) == 0 else {
            return ""
        }

        return String(cString: buffer)
    }

    public func walk() -> [ThreadStack] {
        Self.exclusive.lock()
        defer { Self.exclusive.unlock() }
        return walkExclusively()
    }

    private func walkExclusively() -> [ThreadStack] {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
              let threads = list
        else {
            return []
        }

        defer {
            for index in 0 ..< Int(count) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        guard count <= Self.maxThreads else {
            return []
        }

        let walking = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, walking) }
        let main = MainThreadPort.port

        let total = Int(count)

        // Before the suspend: pthread_getname_np takes a lock a suspended
        // thread may hold, so every name is read while everything still runs.
        var names = [String]()
        names.reserveCapacity(total)
        for index in 0 ..< total {
            names.append(Self.name(of: threads[index]))
        }

        var stacks = [ThreadStack]()
        stacks.reserveCapacity(total)

        // One row of frames per thread and one count per thread, both reserved
        // out here. Entering these closures is where the memory is taken, which
        // is why the suspend happens inside them rather than around them: an
        // allocation between suspend and resume can block on the malloc lock a
        // suspended thread is holding, and that deadlock has no timeout.
        withUnsafeTemporaryAllocation(of: Int.self, capacity: total) { taken in
            withUnsafeTemporaryAllocation(
                of: UInt64.self,
                capacity: total * Self.maxFrames
            ) { buffer in
                // ── Nothing from here to the resume may allocate. ──
                for index in 0 ..< total where threads[index] != walking {
                    thread_suspend(threads[index])
                }

                for index in 0 ..< total where threads[index] != walking {
                    let row = UnsafeMutableBufferPointer(
                        rebasing: buffer[(index * Self.maxFrames) ..<
                            ((index + 1) * Self.maxFrames)]
                    )
                    taken[index] = Self.unwind(threads[index], into: row)
                }

                for index in 0 ..< total where threads[index] != walking {
                    thread_resume(threads[index])
                }
                // ── Running again; Swift objects are safe to build. ──

                for index in 0 ..< total where threads[index] != walking {
                    let start = index * Self.maxFrames
                    stacks.append(
                        ThreadStack(
                            index: index,
                            name: names[index],
                            isMain: main != 0 && threads[index] == main,
                            frames: Array(buffer[start ..< (start + taken[index])])
                        )
                    )
                }
            }
        }
        return stacks
    }
}

/// The main thread's port, taken while the main thread is still answering and
/// read long after it has stopped. Asking for it at the moment of a hang is
/// asking the one thread that cannot reply, so it is captured when the
/// instrument activates and only read when something has gone wrong.
public final class MainThreadPort: @unchecked Sendable {
    private nonisolated(unsafe) static let slot: UnsafeMutablePointer<UInt64> =
        .allocate(capacity: 1)
    private static let once: Void = {
        Atomics.initialize(slot, 0)
    }()

    /// Zero when the main thread never answered, which reads as "no thread is
    /// marked main" rather than as the wrong thread being marked.
    public static var port: thread_t {
        _ = once
        return thread_t(Atomics.loadRelaxed(slot))
    }

    /// Called from anywhere, and answered immediately only when the caller is
    /// already the main thread.
    ///
    /// Off the main thread this can do no better than ask the main queue, which
    /// is precisely the arrangement that fails when it matters: a main thread
    /// already stuck never runs the block, so the port stays zero and the thread
    /// the reader most wants identified is the one left unmarked. `Basset.start`
    /// therefore captures it at launch, while the app is still healthy, so that
    /// by the time an instrument activates this is a no-op.
    public static func capture() {
        _ = once
        guard Atomics.loadRelaxed(slot) == 0 else {
            return
        }

        if Thread.isMainThread {
            Atomics.storeRelaxed(slot, UInt64(pthread_mach_thread_np(pthread_self())))
            return
        }
        DispatchQueue.main.async {
            guard Atomics.loadRelaxed(slot) == 0 else {
                return
            }

            Atomics.storeRelaxed(slot, UInt64(pthread_mach_thread_np(pthread_self())))
        }
    }
}
