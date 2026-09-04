import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The kernel's `user_tag` on a VM region, named. The numbers are `VM_MEMORY_*` from
/// `<mach/vm_statistics.h>`; the names are what a reader would call the owner.
enum VMTag {
    static let names: [UInt32: String] = [
        0: "untagged",
        1: "malloc",
        2: "malloc small",
        3: "malloc large",
        4: "malloc huge",
        5: "sbrk",
        6: "realloc",
        7: "malloc tiny",
        8: "malloc large reusable",
        9: "malloc large reused",
        10: "analysis tool",
        11: "malloc nano",
        12: "malloc medium",
        13: "malloc probabilistic guard",
        20: "mach messages",
        21: "IOKit",
        22: "VM reclaim",
        30: "thread stacks",
        31: "guard pages",
        32: "shared pmap",
        33: "dylib",
        34: "objc dispatchers",
        35: "unshared pmap",
        36: "libchannel",
        40: "AppKit",
        41: "Foundation",
        42: "CoreGraphics",
        43: "CoreServices",
        44: "Java",
        45: "CoreData",
        46: "CoreData object ids",
        50: "ATS",
        51: "Core Animation",
        52: "CGImage",
        53: "tcmalloc",
        54: "CoreGraphics image data",
        55: "CoreGraphics shared",
        56: "CoreGraphics framebuffers",
        57: "CoreGraphics backing stores",
        58: "CoreGraphics xalloc",
        60: "dyld",
        61: "dyld malloc",
        62: "SQLite",
        63: "JavaScriptCore",
        64: "JavaScript JIT",
        65: "JavaScript JIT register file",
        66: "GLSL",
        67: "OpenCL",
        68: "Core Image",
        69: "WebCore purgeable buffers",
        70: "ImageIO",
        71: "CoreProfile",
        72: "assetsd",
        73: "os_alloc_once",
        74: "libdispatch",
        75: "Accelerate",
        76: "CoreUI",
        77: "CoreUI file",
        78: "Genealogy",
        79: "RawCamera",
        80: "corpse info",
        81: "ASL",
        82: "Swift runtime",
        83: "Swift metadata",
        84: "DHMM",
        85: "DFR",
        86: "SceneKit",
        87: "Skywalk",
        88: "IOSurface",
        89: "libnetwork",
        90: "audio",
        91: "video bitstream",
        92: "CoreMedia XPC",
        93: "CoreMedia RPC",
        94: "CoreMedia memory pool",
        95: "CoreMedia read cache",
        96: "CoreMedia CRABS",
        97: "QuickLook thumbnails",
        98: "Accounts",
        99: "sanitizer",
        100: "IOAccelerator (Metal)",
        101: "CoreMedia regwarp",
        102: "EAR decoder",
        103: "CoreUI cached image data",
        104: "ColorSync",
        105: "BTInfo",
        106: "CoreMedia HLS",
        107: "Compositor services",
    ]

    static func name(_ tag: UInt32) -> String {
        if let name = names[tag] {
            return name
        }
        if (240...255).contains(tag) {
            return "app-specific \(tag - 239)"
        }
        return "tag \(tag)"
    }
}

struct VMRegionTotals: Equatable {
    var tag: UInt32
    var residentBytes: UInt64
    var dirtyBytes: UInt64
    var compressedBytes: UInt64
    var regionCount: UInt32
}

/// Identity is where a region sits and how much is mapped; resident pages change under it.
struct VMRegion: Equatable, Hashable {
    let address: UInt64
    let mappedBytes: UInt64
    let residentBytes: UInt64
    let dirtyBytes: UInt64
    let compressedBytes: UInt64
    let tag: UInt32

    init(
        address: UInt64,
        mappedBytes: UInt64,
        residentBytes: UInt64,
        dirtyBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0,
        tag: UInt32
    ) {
        self.address = address
        self.mappedBytes = mappedBytes
        self.residentBytes = residentBytes
        self.dirtyBytes = dirtyBytes
        self.compressedBytes = compressedBytes
        self.tag = tag
    }

    static func == (lhs: VMRegion, rhs: VMRegion) -> Bool {
        lhs.address == rhs.address && lhs.mappedBytes == rhs.mappedBytes && lhs.tag == rhs.tag
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(address)
        hasher.combine(mappedBytes)
        hasher.combine(tag)
    }
}

/// One pass over the process's VM map. Submaps (the shared cache) are skipped: their pages
/// belong to every process and never count against this one.
enum VMRegionWalk {
    typealias Probe = (
        _ address: inout vm_address_t,
        _ size: inout vm_size_t,
        _ info: inout vm_region_submap_info_data_64_t
    ) -> kern_return_t

    static let ioSurfaceTag: UInt32 = 88

    private static let infoWords = mach_msg_type_number_t(
        MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<Int32>.size
    )

    private static let liveProbe: Probe = { address, size, info in
        var depth: natural_t = 0
        var count = infoWords
        return withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                vm_region_recurse_64(mach_task_self_, &address, &size, &depth, $0, &count)
            }
        }
    }

    static func totalsByTag() -> [VMRegionTotals] {
        totalsByTag(regions())
    }

    static func totalsByTag(_ regions: [VMRegion]) -> [VMRegionTotals] {
        var byTag = [UInt32: VMRegionTotals]()
        for region in regions {
            var totals = byTag[region.tag] ?? VMRegionTotals(
                tag: region.tag,
                residentBytes: 0,
                dirtyBytes: 0,
                compressedBytes: 0,
                regionCount: 0
            )
            totals.residentBytes &+= region.residentBytes
            totals.dirtyBytes &+= region.dirtyBytes
            totals.compressedBytes &+= region.compressedBytes
            totals.regionCount &+= 1
            byTag[region.tag] = totals
        }
        return byTag.values.sorted {
            $0.dirtyBytes > $1.dirtyBytes || ($0.dirtyBytes == $1.dirtyBytes && $0.tag < $1.tag)
        }
    }

    /// Every region under one tag, as placed — the identity a later walk can diff against.
    static func regions(tag: UInt32) -> [VMRegion] {
        regions().filter { $0.tag == tag }
    }

    static func regions(probe: Probe = liveProbe) -> [VMRegion] {
        let pageBytes = UInt64(vm_kernel_page_size)
        var found = [VMRegion]()
        forEachRegion(probe: probe) { info, address, size in
            found.append(VMRegion(
                address: UInt64(address),
                mappedBytes: UInt64(size),
                residentBytes: UInt64(info.pages_resident) * pageBytes,
                dirtyBytes: UInt64(info.pages_dirtied) * pageBytes,
                compressedBytes: UInt64(info.pages_swapped_out) * pageBytes,
                tag: info.user_tag
            ))
        }
        return found
    }

    private static func forEachRegion(
        probe: Probe,
        _ visit: (vm_region_submap_info_data_64_t, vm_address_t, vm_size_t) -> Void
    ) {
        var address: vm_address_t = 0
        while true {
            var size: vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            guard probe(&address, &size, &info) == KERN_SUCCESS, size > 0 else {
                break
            }

            if info.is_submap == 0 {
                visit(info, address, size)
            }
            let next = address.addingReportingOverflow(size)
            guard !next.overflow else {
                break
            }

            address = next.partialValue
        }
    }
}
