import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One thread as the kernel describes it, read without stopping it.
public struct ThreadSample: Sendable, Equatable {
    /// Where the thread sat in this call's list. Positional and reused as
    /// threads come and go, which is why it is not what ties two samples of the
    /// same thread together.
    public let index: Int
    /// The kernel's own 64-bit thread id. Stable for the life of the thread, so
    /// a rate computed between two reads is computed for the same thread.
    public let identifier: UInt64
    public let name: String
    public let runState: String
    /// A thread the scheduler parked, as opposed to one waiting on work. Counted
    /// separately because an app with forty idle threads is a different finding
    /// from one with forty busy ones.
    public let isIdle: Bool
    public let isMain: Bool
    /// The kernel's own scaled usage, out of `TH_USAGE_SCALE`.
    public let cpuUsageRatio: Float
    /// Cumulative since the thread started, in nanoseconds. The unit is measured
    /// rather than assumed — the header says only "user run time" — and a rate
    /// built on the wrong one is the plausible-but-wrong kind of number.
    public let userNanoseconds: UInt64
    public let systemNanoseconds: UInt64
    public let currentPriority: Int32
    public let basePriority: Int32

    public var cpuNanoseconds: UInt64 {
        userNanoseconds &+ systemNanoseconds
    }

    /// The scheduler is running this thread above the priority it asked for,
    /// which is what priority donation looks like from outside: something more
    /// urgent is waiting on it. The inversion itself is not observable — what is
    /// being waited on is not readable — so this is the footprint, not the fact.
    public var isPriorityBoosted: Bool {
        currentPriority > basePriority
    }
}

/// Every thread in the process, described but never stopped.
///
/// The counterpart to `ThreadWalker`, and deliberately a different type. That one
/// suspends the world to read stacks and may only run when something has already
/// gone wrong; this one asks the kernel what it already knows and costs two Mach
/// calls per thread. Same subject, different price, which is why
/// `runtime.threadSnapshot` is faults only and everything here is on demand.
///
/// **`task_threads` hands out a send right per thread and the array itself.**
/// Both are this caller's to release: a sampler that forgets overflows the
/// process's port table in under two hours at 10 Hz, and the failure is a dead
/// app rather than a missing reading.
public enum ThreadInventory {
    public static func read() -> [ThreadSample] {
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

        let main = MainThreadPort.port
        var samples = [ThreadSample]()
        samples.reserveCapacity(Int(count))

        for index in 0 ..< Int(count) {
            let thread = threads[index]
            guard let extended = extended(thread) else {
                continue
            }

            samples.append(
                ThreadSample(
                    index: index,
                    identifier: identifier(thread),
                    name: name(in: extended),
                    runState: runState(extended.pth_run_state),
                    isIdle: extended.pth_flags & TH_FLAGS_IDLE != 0,
                    isMain: main != 0 && thread == main,
                    cpuUsageRatio: Float(extended.pth_cpu_usage) / Float(TH_USAGE_SCALE),
                    userNanoseconds: extended.pth_user_time,
                    systemNanoseconds: extended.pth_system_time,
                    currentPriority: extended.pth_curpri,
                    basePriority: extended.pth_priority
                )
            )
        }
        return samples
    }

    private static func extended(_ thread: thread_t) -> thread_extended_info_data_t? {
        var info = thread_extended_info_data_t()
        var count = words(thread_extended_info_data_t.self)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Zero when the kernel declined, which reads as "this thread has no id to
    /// tie samples by" and drops it from any rate rather than pairing it with
    /// the wrong thread.
    private static func identifier(_ thread: thread_t) -> UInt64 {
        var info = thread_identifier_info_data_t()
        var count = words(thread_identifier_info_data_t.self)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.thread_id : 0
    }

    /// The name is a fixed C buffer, so it is read to the first NUL rather than
    /// to the end — the tail is whatever was there before.
    private static func name(in info: thread_extended_info_data_t) -> String {
        withUnsafeBytes(of: info.pth_name) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            guard length > 0 else {
                return ""
            }

            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
    }

    private static func runState(_ raw: Int32) -> String {
        switch raw {
        case TH_STATE_RUNNING: "running"
        case TH_STATE_STOPPED: "stopped"
        case TH_STATE_WAITING: "waiting"
        case TH_STATE_UNINTERRUPTIBLE: "uninterruptible"
        case TH_STATE_HALTED: "halted"
        default: "unrecognised(\(raw))"
        }
    }

    /// The `*_COUNT` macros do not import into Swift — the headers mark them
    /// "structure not supported" — so the word count is taken from the layout,
    /// the same way `MemoryLedger` takes `task_vm_info`'s.
    private static func words<Info>(_ type: Info.Type) -> mach_msg_type_number_t {
        mach_msg_type_number_t(MemoryLayout<Info>.size / MemoryLayout<natural_t>.size)
    }
}

/// task_power_info_data_t()
public struct ProcessWakeups: Sendable, Equatable {
    public let interrupts: UInt64
    public let platformIdle: UInt64

    public static func read() -> ProcessWakeups? {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        return ProcessWakeups(
            interrupts: info.task_interrupt_wakeups,
            platformIdle: info.task_platform_idle_wakeups
        )
    }
}
