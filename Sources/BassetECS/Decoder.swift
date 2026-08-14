import Foundation

public struct DecodedComponent: Equatable, Sendable {
    public let id: UInt16
    public let scalar: Scalar
    public let value: ComponentValue

    public var known: Component.ID? {
        Component.ID(rawValue: id)
    }
}

public struct DecodedEntity: Equatable, Sendable {
    public let id: UInt16
    public let capturedAt: UInt64
    public let components: [DecodedComponent]

    public var known: Entity.ID? {
        Entity.ID(rawValue: id)
    }
}

public enum Frame: Equatable, Sendable {
    case manifest([AdvertisedInstrument])
    case entity(DecodedEntity)
}

public enum DecoderError: Error, Equatable {
    case truncated
    case unknownScalar(UInt8)
    case unknownPayloadKind(UInt8)
    case frameTooLarge(UInt64)
    case uvarintTooLong
    case stringNotUtf8
}

public struct FrameReader {
    public static let maxFrameLength: UInt64 = 1024 * 1024

    private let bytes: [UInt8]
    private var offset: Int

    public var isAtEnd: Bool {
        offset >= bytes.count
    }

    public init(_ data: Data) {
        self.bytes = Array(data)
        self.offset = 0
    }

    public static func frames(in data: Data) throws -> [Frame] {
        var reader = FrameReader(data)
        var frames = [Frame]()
        while let frame = try reader.next() {
            frames.append(frame)
        }
        return frames
    }

    public mutating func next() throws -> Frame? {
        if isAtEnd {
            return nil
        }
        let length = try readUvarint()
        guard length <= Self.maxFrameLength
        else {
            throw DecoderError.frameTooLarge(length)
        }
        guard offset + Int(length) <= bytes.count else {
            throw DecoderError.truncated
        }

        var payload = PayloadReader(
            bytes: bytes,
            start: offset,
            end: offset + Int(length)
        )
        offset += Int(length)
        return try payload.frame()
    }

    private mutating func readUvarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else {
                throw DecoderError.truncated
            }

            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            guard shift < 64 else {
                throw DecoderError.uvarintTooLong
            }
        }
    }
}

private struct PayloadReader {
    let bytes: [UInt8]
    var start: Int
    let end: Int

    mutating func frame() throws -> Frame {
        let raw = try byte()
        guard let kind = PayloadKind(rawValue: raw) else {
            throw DecoderError.unknownPayloadKind(raw)
        }

        switch kind {
        case .manifest: return try .manifest(manifest())
        case .entity: return try .entity(entity())
        }
    }

    private mutating func manifest() throws -> [AdvertisedInstrument] {
        let count = try records(eachTakingAtLeast: 3)
        var instruments = [AdvertisedInstrument]()
        instruments.reserveCapacity(count)
        for _ in 0 ..< count {
            let id = try fixedWidth(UInt16.self)
            let emitCount = try records(eachTakingAtLeast: 2)
            var emits = [UInt16]()
            emits.reserveCapacity(emitCount)
            for _ in 0 ..< emitCount {
                try emits.append(fixedWidth(UInt16.self))
            }
            instruments.append(AdvertisedInstrument(id: id, emits: emits))
        }
        return instruments
    }

    private mutating func entity() throws -> DecodedEntity {
        let id = try fixedWidth(UInt16.self)
        let capturedAt = try fixedWidth(UInt64.self)
        let count = try records(eachTakingAtLeast: 4)
        var components = [DecodedComponent]()
        components.reserveCapacity(count)
        for _ in 0 ..< count {
            let componentId = try fixedWidth(UInt16.self)
            let raw = try byte()
            guard let scalar = Scalar(rawValue: raw)
            else {
                throw DecoderError.unknownScalar(raw)
            }

            try components.append(
                DecodedComponent(
                    id: componentId,
                    scalar: scalar,
                    value: value(scalar)
                )
            )
        }
        return DecodedEntity(id: id, capturedAt: capturedAt, components: components)
    }

    private mutating func value(_ scalar: Scalar) throws -> ComponentValue {
        switch scalar {
        case .int8: return try .int8(Int8(bitPattern: byte()))
        case .int16: return try .int16(Int16(bitPattern: fixedWidth(UInt16.self)))
        case .int32: return try .int32(Int32(bitPattern: fixedWidth(UInt32.self)))
        case .int64: return try .int64(Int64(bitPattern: fixedWidth(UInt64.self)))
        case .uint8: return try .uint8(byte())
        case .uint16: return try .uint16(fixedWidth(UInt16.self))
        case .uint32: return try .uint32(fixedWidth(UInt32.self))
        case .uint64: return try .uint64(fixedWidth(UInt64.self))
        case .float32: return try .float32(Float(bitPattern: fixedWidth(UInt32.self)))
        case .float64: return try .float64(Double(bitPattern: fixedWidth(UInt64.self)))
        case .bool: return try .bool(byte() != 0)
        case .string:
            let length = try Int(byte())
            guard start + length <= end else {
                throw DecoderError.truncated
            }

            let slice = bytes[start ..< (start + length)]
            start += length
            guard let text = String(bytes: slice, encoding: .utf8) else {
                throw DecoderError.stringNotUtf8
            }

            return .string(text)
        }
    }

    private mutating func byte() throws -> UInt8 {
        guard start < end else {
            throw DecoderError.truncated
        }

        defer { start += 1 }
        return bytes[start]
    }

    private mutating func fixedWidth<T: FixedWidthInteger & UnsignedInteger>(_: T
        .Type) throws -> T
    {
        let width = MemoryLayout<T>.size
        guard start + width <= end else {
            throw DecoderError.truncated
        }

        var result: T = 0
        for index in 0 ..< width {
            result |= T(bytes[start + index]) << (8 * index)
        }
        start += width
        return result
    }

    /// Checked against remaining bytes before reserving, so a claimed billion can't allocate one.
    private mutating func records(eachTakingAtLeast size: Int) throws -> Int {
        let declared = try uvarint()
        guard declared <= UInt64((end - start) / size) else {
            throw DecoderError.truncated
        }

        return Int(declared)
    }

    private mutating func uvarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try byte()
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            guard shift < 64 else {
                throw DecoderError.uvarintTooLong
            }
        }
    }
}
