import Foundation
import MachO

public struct BinaryImage: Sendable {
    public let name: String
    public let loadAddress: UInt64
    public let size: UInt64
    public let uuid: String

    public func contains(_ address: UInt64) -> Bool {
        address >= loadAddress && address < loadAddress &+ size
    }
}

/// What dyld has mapped, and the `LC_UUID` of each image.
///
/// The UUID is the join key to the developer's own machine: the build that
/// produced the app carries the same one in its `.dSYM`, so an address and a
/// load address are enough to symbolicate locally without anything being
/// uploaded or hosted. A stack from a build they no longer have says so, rather
/// than resolving to the wrong lines.
public enum BinaryImages {
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

    /// The app's own binary. Identifies the build every other reading came from,
    /// which is why it rides on `device.info` rather than only on a stack.
    public static func mainExecutable() -> BinaryImage? {
        loaded().first { $0.isMainExecutable }
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
            uuid: uuid
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

extension BinaryImage {
    var isMainExecutable: Bool {
        loadAddress == UInt64(UInt(bitPattern: _dyld_get_image_header(0)))
    }
}
