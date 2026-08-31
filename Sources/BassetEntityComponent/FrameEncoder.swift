import Foundation

public enum PayloadKind: UInt8, Sendable {
    case manifest = 0
    case entity = 1
}

public struct FrameEncoder {
    /// One byte carries the length, so this is the format's ceiling, not a policy.
    static let maxStringBytes = 255

    public init() {}

    /// Cut on a character boundary: a byte cut mid-character made invalid UTF-8, refusing frames.
    private static func utf8(of value: String) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(min(value.utf8.count, maxStringBytes))
        for character in value {
            let encoded = character.utf8
            guard bytes.count + encoded.count <= maxStringBytes else {
                break
            }

            bytes.append(contentsOf: encoded)
        }
        return bytes
    }

    public func frame(_ payload: Data) -> Data {
        var out = Data()
        appendUvarint(UInt64(payload.count), to: &out)
        out.append(payload)
        return out
    }

    public func hello(_ instruments: [AdvertisedInstrument]) -> Data {
        var out = Data([PayloadKind.manifest.rawValue])
        appendUvarint(UInt64(instruments.count), to: &out)
        for instrument in instruments {
            appendLittleEndian(instrument.id, to: &out)
            appendUvarint(UInt64(instrument.emits.count), to: &out)
            for component in instrument.emits {
                appendLittleEndian(component, to: &out)
            }
        }
        return out
    }

    public func encode(_ entity: Entity) -> Data {
        var out = Data([PayloadKind.entity.rawValue])
        appendLittleEndian(entity.id, to: &out)
        appendLittleEndian(entity.capturedAt, to: &out)
        appendUvarint(UInt64(entity.components.count), to: &out)
        for component in entity.components {
            appendLittleEndian(component.id, to: &out)
            out.append(component.value.scalar.rawValue)
            append(component.value, to: &out)
        }
        return out
    }

    public func connectionHeader(token: String) -> Data {
        var out = Data()
        let utf8 = Array(token.utf8)
        appendUvarint(UInt64(utf8.count), to: &out)
        out.append(contentsOf: utf8)
        return out
    }

    private func appendUvarint(_ value: UInt64, to out: inout Data) {
        var remaining = value
        while true {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            out.append(byte)
            if remaining == 0 {
                break
            }
        }
    }

    private func append(_ value: ComponentValue, to out: inout Data) {
        switch value {
        case .int8(let value): out.append(UInt8(bitPattern: value))
        case .int16(let value): appendLittleEndian(UInt16(bitPattern: value), to: &out)
        case .int32(let value): appendLittleEndian(UInt32(bitPattern: value), to: &out)
        case .int64(let value): appendLittleEndian(UInt64(bitPattern: value), to: &out)
        case .uint8(let value): out.append(value)
        case .uint16(let value): appendLittleEndian(value, to: &out)
        case .uint32(let value): appendLittleEndian(value, to: &out)
        case .uint64(let value): appendLittleEndian(value, to: &out)
        case .float32(let value): appendLittleEndian(value.bitPattern, to: &out)
        case .float64(let value): appendLittleEndian(value.bitPattern, to: &out)
        case .bool(let value): out.append(value ? 1 : 0)
        case .string(let value):
            let utf8 = Self.utf8(of: value)
            out.append(UInt8(utf8.count))
            out.append(contentsOf: utf8)
        }
    }

    private func appendLittleEndian(_ value: some FixedWidthInteger, to out: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { out.append(contentsOf: $0) }
    }
}
