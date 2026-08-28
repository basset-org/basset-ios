import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One thread as the kernel describes it, read without stopping it.
public struct ThreadSample: Sendable, Equatable {
    /// Positional and reused as threads come and go — not what ties two samples together.
    public let index: Int
    /// Stable for the life of the thread, so a rate computed between two reads is valid.
    public let identifier: UInt64
    public let name: String
    public let runState: String
    /// Waiting, burning nothing — forty idle threads differs from forty busy ones.
    public let isIdle: Bool
    /// What was requested, not what's running — priority donation raises the latter.
    public let requestedQos: String
    public let isMain: Bool
    /// The kernel's own scaled usage, out of `TH_USAGE_SCALE`.
    public let cpuUsageRatio: Float
    /// Measured, not assumed: the header only documents it as "user run time".
    public let userNanoseconds: UInt64
    public let systemNanoseconds: UInt64
    public let currentPriority: Int32
    public let basePriority: Int32

    public var cpuNanoseconds: UInt64 {
        userNanoseconds &+ systemNanoseconds
    }
}

/// ThreadWalker's counterpart: two Mach calls per thread; never suspends the world.
public enum ThreadInventory {
    /// What one enumeration saw, and whether it saw all of it.
    public struct Snapshot: Sendable {
        public let samples: [ThreadSample]
        /// False when the kernel refused a thread mid-enumeration, which it does for one
        /// exiting as it is read. An id absent from an incomplete snapshot proves nothing
        /// about whether that thread was running.
        public let isComplete: Bool
    }

    public static func read() -> [ThreadSample] {
        snapshot().samples
    }

    public static func snapshot() -> Snapshot {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
              let threads = list
        else {
            return Snapshot(samples: [], isComplete: false)
        }

        // A send right per thread, plus the array — unreleased, ports overflow in hours.
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

        var refused = false
        for index in 0 ..< Int(count) {
            let thread = threads[index]
            guard let extended = extended(thread) else {
                refused = true
                continue
            }

            samples.append(
                ThreadSample(
                    index: index,
                    identifier: identifier(thread),
                    name: name(in: extended),
                    runState: runState(extended.pth_run_state),
                    // TH_FLAGS_IDLE marks kernel idle threads only, never an app thread.
                    isIdle: extended.pth_run_state == TH_STATE_WAITING
                        && extended.pth_cpu_usage == 0,
                    requestedQos: requestedQos(thread),
                    isMain: main != 0 && thread == main,
                    cpuUsageRatio: Float(extended.pth_cpu_usage) / Float(TH_USAGE_SCALE),
                    userNanoseconds: extended.pth_user_time,
                    systemNanoseconds: extended.pth_system_time,
                    currentPriority: extended.pth_curpri,
                    basePriority: extended.pth_priority
                )
            )
        }
        return Snapshot(samples: samples, isComplete: !refused)
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

    /// What was asked for — the scheduler's priority fields report what it settled on.
    private static func requestedQos(_ thread: thread_t) -> String {
        guard let handle = pthread_from_mach_thread_np(thread) else {
            return "unspecified"
        }

        var requested = qos_class_t(rawValue: 0)
        guard pthread_get_qos_class_np(handle, &requested, nil) == 0 else {
            return "unspecified"
        }

        switch requested {
        case QOS_CLASS_BACKGROUND: return "background"
        case QOS_CLASS_UTILITY: return "utility"
        case QOS_CLASS_DEFAULT: return "default"
        case QOS_CLASS_USER_INITIATED: return "userInitiated"
        case QOS_CLASS_USER_INTERACTIVE: return "userInteractive"
        default: return "unspecified"
        }
    }

    /// Zero when the kernel declined — dropped from a rate rather than paired wrongly.
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

    /// Fixed C buffer read to the first NUL — the tail is whatever was there before.
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

    /// `*_COUNT` macros don't import into Swift; word count comes from the layout instead.
    private static func words<Info>(_ type: Info.Type) -> mach_msg_type_number_t {
        mach_msg_type_number_t(MemoryLayout<Info>.size / MemoryLayout<natural_t>.size)
    }
}

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
