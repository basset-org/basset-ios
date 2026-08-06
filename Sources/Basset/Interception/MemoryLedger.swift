import BassetECS
import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS)
import os
#endif

/// The three numbers jetsam decides on, read together in one Mach round trip.
///
/// A footprint on its own cannot be acted on. 400 MB is unremarkable against a
/// 3 GB limit and one allocation from death against a 400 MB one, and the limit
/// is not a property of the hardware — it moves during the app's life, so it is
/// read rather than remembered.
///
/// The limit is the sum rather than a field: the kernel reports what is left,
/// and what was allowed is that plus what has been taken.
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

    let usedBytes: UInt64
    let availableBytes: UInt64?

    var limitBytes: UInt64? {
        availableBytes.map { usedBytes + $0 }
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
            availableBytes: headroom(from: info, wordsWritten: wordsWritten)
        )
    }

    /// `limit_bytes_remaining` is a late addition to `task_vm_info`, and a kernel
    /// that predates it writes back a shorter structure while leaving the tail of
    /// ours as whatever was on the stack. How many words it wrote is the only
    /// thing that says whether the field was answered.
    private static func headroom(
        from info: task_vm_info_data_t,
        wordsWritten: mach_msg_type_number_t
    ) -> UInt64? {
        if wordsWritten >= wordsThroughRemainingBytes {
            return info.limit_bytes_remaining
        }
        #if os(iOS)
        // Zero here is ambiguous by documentation — it is what a process
        // over its limit reads and what a process with no limit of its own
        // reads — so it is reported as no answer rather than as no memory.
        let reported = os_proc_available_memory()
        if reported > 0 {
            return UInt64(reported)
        }
        #endif
        return nil
    }

    func write(into out: inout Readings) {
        out.put(.memoryUsedBytes(usedBytes))
        guard let availableBytes, let limitBytes else {
            return
        }

        out.put(.memoryAvailableBytes(availableBytes))
        out.put(.memoryLimitBytes(limitBytes))
    }
}
