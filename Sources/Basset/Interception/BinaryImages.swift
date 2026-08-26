import Foundation
import MachO

public struct BinaryImage: Sendable {
    public let name: String
    public let loadAddress: UInt64
    public let size: UInt64
    public let uuid: String
    /// From the mach-o file type — dyld's first mapped image is not reliably the main one.
    public let isMainExecutable: Bool
    /// Kept to say where an image came from; never emitted — a full path leaks install dirs.
    public let path: String

    /// Whether the image came from the app bundle rather than from the OS.
    public func isInAppBundle(under directory: String) -> Bool {
        guard !directory.isEmpty else {
            return false
        }

        // Boundary check, not text: `Name.appex` sits beside, not inside, `Name.app`.
        return path == directory || path.hasPrefix(directory + "/")
    }

    public func contains(_ address: UInt64) -> Bool {
        address >= loadAddress && address < loadAddress &+ size
    }
}

/// What dyld has mapped; the UUID joins a stack to the developer's own local `.dSYM`.
public enum BinaryImages {
    /// Built once — allocating this per image was most of the scan's cost.
    private static let textSegmentName: Array = .init(SEG_TEXT.utf8)

    /// Each image's start/end, ascending, no strings built — naming them cost the most.
    /// Every image is described where it is walked, so nothing is later looked up by a dyld
    /// index a dlopen could have moved. A hold stale by an unload and a load of equal count
    /// can answer with an image that is gone, never name the wrong one.
    private static let held: Mutex<(count: UInt32, images: [BinaryImage])> = .init((0, []))

    public static func loaded() -> [BinaryImage] {
        var images = [BinaryImage]()
        for index in 0 ..< _dyld_image_count() {
            guard let header = _dyld_get_image_header(index),
                  let path = _dyld_get_image_name(index)
            else {
                continue
            }

            let slide = _dyld_get_image_vmaddr_slide(index)
            guard let described = describe(
                header,
                slide: slide,
                path: String(cString: path)
            )
            else {
                continue
            }

            images.append(described)
        }
        return images
    }

    /// The build every other reading came from; rides on `device.info`, not only a stack.
    public static func mainExecutable() -> BinaryImage? {
        loaded().first { $0.isMainExecutable }
    }

    /// The app's own directory, by mach-o type — `Bundle.main` is the test host, not the app.
    public static func appBundleDirectory() -> String {
        for index in 0 ..< _dyld_image_count() {
            guard let header = _dyld_get_image_header(index),
                  header.pointee.filetype == UInt32(MH_EXECUTE),
                  let path = _dyld_get_image_name(index)
            else {
                continue
            }

            return bundleRoot(of: String(cString: path))
        }

        return ""
    }

    /// Only images an address lands in; a process maps hundreds, a stack touches a few.
    public static func covering(_ addresses: some Sequence<UInt64>) -> [BinaryImage] {
        let images = mappedImages()
        var matched = [String: BinaryImage]()
        for address in addresses {
            guard let image = images.first(where: {
                address >= $0.loadAddress && address < $0.loadAddress &+ $0.size
            }) else {
                continue
            }

            matched[image.uuid] = image
        }

        return matched.values.sorted { $0.loadAddress < $1.loadAddress }
    }

    /// The nearest enclosing bundle, or the executable's directory when there is none.
    static func bundleRoot(of executable: String) -> String {
        // Walked up, not the parent dir — iOS and macOS bundles nest to different depths.
        var directory = (executable as NSString).deletingLastPathComponent
        while !directory.isEmpty, directory != "/" {
            let name = (directory as NSString).lastPathComponent
            if name.hasSuffix(".app") || name.hasSuffix(".appex")
                || name.hasSuffix(".xctest") || name.hasSuffix(".framework")
            {
                return directory
            }

            directory = (directory as NSString).deletingLastPathComponent
        }

        return (executable as NSString).deletingLastPathComponent
    }

    private static func mappedImages() -> [BinaryImage] {
        let counted = _dyld_image_count()
        if let cached = held.withLock({ $0.count == counted ? $0.images : nil }) {
            return cached
        }

        let walked = (0 ..< counted)
            .compactMap { describe(at: $0) }
            .sorted { $0.loadAddress < $1.loadAddress }
        held.withLock { $0 = (counted, walked) }
        return walked
    }

    private static func walkMappedSpans() -> [ImageSpan] {
        var spans = [ImageSpan]()
        spans.reserveCapacity(Int(_dyld_image_count()))
        for index in 0 ..< _dyld_image_count() {
            guard let header = _dyld_get_image_header(index), isSixtyFourBit(header) else {
                continue
            }

            spans.append(
                ImageSpan(
                    index: index,
                    loadAddress: UInt64(UInt(bitPattern: UnsafeRawPointer(header))),
                    size: textSize(of: header)
                )
            )
        }
        return spans.sorted { $0.loadAddress < $1.loadAddress }
    }

    private static func describe(at index: UInt32) -> BinaryImage? {
        guard let header = _dyld_get_image_header(index),
              let path = _dyld_get_image_name(index)
        else {
            return nil
        }

        return describe(
            header,
            slide: _dyld_get_image_vmaddr_slide(index),
            path: String(cString: path)
        )
    }

    private static func isSixtyFourBit(_ header: UnsafePointer<mach_header>) -> Bool {
        header.pointee.magic == MH_MAGIC_64 || header.pointee.magic == MH_CIGAM_64
    }

    /// `__TEXT` length matched byte by byte — building a String cost most of the scan.
    private static func textSize(of header: UnsafePointer<mach_header>) -> UInt64 {
        var cursor = UnsafeRawPointer(header)
            .advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0 ..< header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = cursor.assumingMemoryBound(to: segment_command_64.self)
                if isTextSegment(segment) {
                    return segment.pointee.vmsize
                }
            }

            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return 0
    }

    private static func isTextSegment(
        _ segment: UnsafePointer<segment_command_64>
    ) -> Bool {
        let text = textSegmentName
        return withUnsafeBytes(of: segment.pointee.segname) { name in
            guard name.count > text.count else {
                return false
            }

            for offset in 0 ..< text.count where name[offset] != text[offset] {
                return false
            }

            return name[text.count] == 0
        }
    }

    private static func describe(
        _ header: UnsafePointer<mach_header>,
        slide: Int,
        path: String
    ) -> BinaryImage? {
        let base = UnsafeRawPointer(header)
        let is64 = header.pointee.magic == MH_MAGIC_64 || header.pointee
            .magic == MH_CIGAM_64
        guard is64 else {
            return nil
        }

        var cursor = base.advanced(by: MemoryLayout<mach_header_64>.size)
        var uuid = ""
        var text: UInt64 = 0

        for _ in 0 ..< header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee

            if command.cmd == UInt32(LC_UUID) {
                let loaded = cursor.assumingMemoryBound(to: uuid_command.self).pointee
                uuid = render(loaded.uuid)
            }
            if command.cmd == UInt32(LC_SEGMENT_64) {
                let segment = cursor.assumingMemoryBound(to: segment_command_64.self)
                    .pointee
                if segmentName(segment.segname) == SEG_TEXT {
                    text = segment.vmsize
                }
            }

            cursor = cursor.advanced(by: Int(command.cmdsize))
        }

        guard !uuid.isEmpty else {
            return nil
        }

        return BinaryImage(
            name: (path as NSString).lastPathComponent,
            loadAddress: UInt64(UInt(bitPattern: base)),
            size: text,
            uuid: uuid,
            isMainExecutable: header.pointee.filetype == UInt32(MH_EXECUTE),
            path: path
        )
    }

    private static func render(_ bytes: uuid_t) -> String {
        var raw = bytes
        return withUnsafePointer(to: &raw) { slot in
            slot.withMemoryRebound(to: UInt8.self, capacity: 16) { octets in
                UUID(uuid: (
                    octets[0], octets[1], octets[2], octets[3],
                    octets[4], octets[5], octets[6], octets[7],
                    octets[8], octets[9], octets[10], octets[11],
                    octets[12], octets[13], octets[14], octets[15]
                )).uuidString
            }
        }
    }

    private static func segmentName(
        _ raw: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
    ) -> String {
        var name = raw
        return withUnsafePointer(to: &name) { slot in
            slot.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
    }
}

struct ImageSpan {
    let index: UInt32
    let loadAddress: UInt64
    let size: UInt64

    func contains(_ address: UInt64) -> Bool {
        address >= loadAddress && address < loadAddress &+ size
    }
}

private extension [ImageSpan] {
    /// Ascending by `loadAddress`; a gap between two mappings belongs to no image at all.
    func index(containing address: UInt64) -> UInt32? {
        var low = 0
        var high = count - 1
        var candidate: ImageSpan?

        while low <= high {
            let middle = low + (high - low) / 2
            if self[middle].loadAddress <= address {
                candidate = self[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        guard let candidate, candidate.contains(address) else {
            return nil
        }

        return candidate.index
    }
}
