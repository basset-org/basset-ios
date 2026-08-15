import Darwin
import Foundation

public struct ThreadStack: Sendable {
    public let index: Int
    public let name: String
    public let isMain: Bool
    public let frames: [UInt64]
    /// True when the walk hit `ThreadWalker.maxFrames` — the stack likely ran deeper than this.
    public let truncated: Bool
}

/// Suspends every thread; between suspend and resume nothing may allocate or take a lock.
public final class ThreadWalker: @unchecked Sendable {
    /// Beyond this, suspending every thread is itself the risk, not the answer.
    public static let maxThreads = 70
    public static let maxFrames = 100

    /// Sanitizers lock inside the suspend window; a suspended holder deadlocks the walk.
    static let isThreadSanitizerLoaded = dlsym(dlopen(nil, RTLD_LAZY), "__tsan_init") != nil

    /// Static, process-wide — two concurrent walks can suspend each other and deadlock.
    private static let exclusive: NSLock = .init()

    /// Longer than any legitimate walk takes; bounds a stuck holder instead of blocking forever.
    private static let exclusiveTimeout: TimeInterval = 2

    public init() {}

    /// Read after an empty walk — the count can cross the ceiling in between otherwise.
    public static func liveThreadCount() -> Int? {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
              let threads = list
        else {
            return nil
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

        return Int(count)
    }

    /// Read right after an empty walk — a lock freed since then reads as free either way.
    public static func exclusiveIsHeld() -> Bool {
        guard exclusive.try() else {
            return true
        }

        exclusive.unlock()
        return false
    }

    // Nothing below this line may allocate: it runs with the process suspended.

    private static func unwind(
        _ thread: thread_t,
        into buffer: UnsafeMutableBufferPointer<UInt64>
    ) -> Int {
        guard var frame = framePointer(of: thread) else {
            return 0
        }

        var taken = 0
        while taken < buffer.count, frame != 0, frame % 2 == 0, frame <= UInt64.max - 8 {
            // A frame is {prior fp, return address}; corrupt data ends the walk, not the app.
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

        // Pointer auth signs the fp on arm64e; stripped here to unwind on either arch.
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
        guard !Self.isThreadSanitizerLoaded else {
            return []
        }
        guard Self.exclusive.lock(before: Date().addingTimeInterval(Self.exclusiveTimeout)) else {
            return []
        }

        defer { Self.exclusive.unlock() }
        return walkExclusively()
    }

    /// Refused before the lock — a waiting main thread could deadlock its own resume.
    public func walkMainThread() -> [UInt64]? {
        guard !Self.isThreadSanitizerLoaded else {
            return nil
        }

        let main = MainThreadPort.port
        guard main != 0 else {
            return nil
        }

        let walking = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, walking) }
        guard main != walking else {
            return nil
        }
        guard Self.exclusive.lock(before: Date().addingTimeInterval(Self.exclusiveTimeout)) else {
            return nil
        }

        defer { Self.exclusive.unlock() }

        var frames = [UInt64]()
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: Self.maxFrames) { buffer in
            // ── Nothing from here to the resume may allocate. ──
            thread_suspend(main)
            let taken = Self.unwind(main, into: buffer)
            thread_resume(main)
            // ── Running again; Swift objects are safe to build. ──
            frames = Array(buffer[0 ..< taken])
        }
        return frames
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

        // Names read before suspend — pthread_getname_np can hold a lock a thread has.
        var names = [String]()
        names.reserveCapacity(total)
        for index in 0 ..< total {
            names.append(Self.name(of: threads[index]))
        }

        var stacks = [ThreadStack]()
        stacks.reserveCapacity(total)

        // Suspended inside the closures — allocating between them risks the malloc lock.
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
                            frames: Array(buffer[start ..< (start + taken[index])]),
                            truncated: taken[index] == Self.maxFrames
                        )
                    )
                }
            }
        }
        return stacks
    }
}

/// The main thread's port, captured early — a hung thread can't answer a request for it.
public final class MainThreadPort: @unchecked Sendable {
    private nonisolated(unsafe) static let slot: UnsafeMutablePointer<UInt64> =
        .allocate(capacity: 1)
    private static let once: Void = {
        Atomics.initialize(slot, 0)
    }()

    /// Zero reads as "no thread is marked main", not as the wrong thread being marked.
    public static var port: thread_t {
        _ = once
        return thread_t(Atomics.loadRelaxed(slot))
    }

    /// Captured at launch — a stuck main thread would never run the async capture block.
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
