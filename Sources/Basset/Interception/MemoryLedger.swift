import BassetEntityComponent
import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS)
import os
#endif

/// Limit is derived (kernel remaining + used), not a field — it moves during app life.
struct MemoryLedger {
    private static let wholeStructureInWords = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )

    private static let wordsThroughRemainingBytes: mach_msg_type_number_t = {
        guard
            let offset = MemoryLayout<task_vm_info_data_t>
            .offset(of: \task_vm_info_data_t.limit_bytes_remaining)
        else {
            return wholeStructureInWords
        }

        return mach_msg_type_number_t(
            (offset + MemoryLayout<UInt64>.size) / MemoryLayout<natural_t>.size
        )
    }()

    /// `mach_host_self()` hands out a new send right per call; one read a second would leak them.
    private static let host: host_t = mach_host_self()

    let usedBytes: UInt64
    let availableBytes: UInt64?
    /// Device-wide, from `host_statistics64`: free plus inactive pages. What a system-scope
    /// pressure warning is about, which the app's own limit says nothing of.
    let systemFreeBytes: UInt64?
    let systemPhysicalBytes: UInt64

    var limitBytes: UInt64? {
        availableBytes.flatMap {
            let (limit, overflowed) = usedBytes.addingReportingOverflow($0)
            return overflowed ? nil : limit
        }
    }

    init(
        usedBytes: UInt64,
        availableBytes: UInt64?,
        systemFreeBytes: UInt64? = nil,
        systemPhysicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.systemFreeBytes = systemFreeBytes
        self.systemPhysicalBytes = systemPhysicalBytes
    }

    static func read() -> MemoryLedger? {
        var info = task_vm_info_data_t()
        var wordsWritten = wholeStructureInWords
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(wordsWritten)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &wordsWritten)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        return MemoryLedger(
            usedBytes: info.phys_footprint,
            availableBytes: headroom(from: info, wordsWritten: wordsWritten),
            systemFreeBytes: systemFree()
        )
    }

    private static func systemFree() -> UInt64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    /// A kernel predating `limit_bytes_remaining` writes fewer words; count says which.
    private static func headroom(
        from info: task_vm_info_data_t,
        wordsWritten: mach_msg_type_number_t
    ) -> UInt64? {
        if wordsWritten >= wordsThroughRemainingBytes {
            return info.limit_bytes_remaining
        }
        #if os(iOS)
        // Zero is ambiguous (over limit, or none) — reported as no answer, not no memory.
        let reported = os_proc_available_memory()
        if reported > 0 {
            return UInt64(reported)
        }
        #endif
        return nil
    }

    func write(into out: inout Readings) {
        out.put(.memoryUsedBytes(usedBytes))
        if let systemFreeBytes {
            out.put(.systemFreeBytes(systemFreeBytes))
            out.put(.systemFreeRatio(Float(systemFreeBytes) / Float(max(systemPhysicalBytes, 1))))
        }

        guard let availableBytes, let limitBytes else {
            return
        }

        out.put(.memoryAvailableBytes(availableBytes))
        out.put(.memoryLimitBytes(limitBytes))
        out.put(.memoryUsageRatio(Float(usedBytes) / Float(max(limitBytes, 1))))
    }
}
