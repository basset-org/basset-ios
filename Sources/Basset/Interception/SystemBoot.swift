import Foundation

enum SystemBoot {
    /// `kern.boottime` — the same value across every run of a launch, so a record
    /// carrying a different one was written before the device restarted.
    static var microseconds: UInt64 {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &boottime, &size, nil, 0) == 0 else {
            return 0
        }

        return UInt64(boottime.tv_sec) * 1000000 + UInt64(boottime.tv_usec)
    }
}
