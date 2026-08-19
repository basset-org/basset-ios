@testable import BassetECS
import Foundation
import Testing

struct DecoderTests {
    private let encoder: FrameEncoder = .init()

    @Test func roundTripsEveryScalar() throws {
        var entity = Entity(.device, capturedAt: 1700000000000123)
        entity.add(.cpuUsageRatio(0.29))
        entity.add(.memoryUsedBytes(4294967296))
        entity.add(.deviceModel("iPhone17,2"))
        entity.add(.instrument(3))
        entity.add(.sessionRunning(true))

        let frames = try FrameReader.frames(in: framed([entity]))

        #expect(frames.count == 1)
        guard case .entity(let decoded) = frames[0] else {
            Issue.record("expected an entity frame")
            return
        }

        #expect(decoded.known == .device)
        #expect(decoded.capturedAt == 1700000000000123)
        #expect(decoded.components.map(\.value) == [
            .float32(0.29), .uint64(4294967296), .string("iPhone17,2"),
            .uint16(3), .bool(true),
        ])
        #expect(decoded.components.map(\.scalar) == [
            .float32, .uint64, .string, .uint16, .bool,
        ])
        #expect(decoded.components.map(\.known) == [
            .cpuUsageRatio, .memoryUsedBytes, .deviceModel, .instrument, .sessionRunning,
        ])
    }

    @Test func readsEveryFixedWidthScalarBackAsWritten() throws {
        let values: [ComponentValue] = [
            .int8(-1), .int16(-300), .int32(-70000), .int64(-5000000000),
            .uint8(200), .uint16(60000), .uint32(4000000000), .uint64(.max),
            .float32(-1.5), .float64(3.141592653589793), .bool(true),
        ]
        var manual = entityHeader(.device, capturedAt: 7, count: UInt8(values.count))
        for value in values {
            manual.append(componentTag(0xfffe, value.scalar))
            manual.append(encodedValue(value))
        }

        let frames = try FrameReader.frames(in: encoder.frame(manual))
        guard case .entity(let decoded) = frames[0] else {
            Issue.record("expected an entity frame")
            return
        }

        #expect(decoded.components.map(\.value) == values)
    }

    @Test func anUnknownComponentIdKeepsItsValueAndReportsNoCatalogEntry() throws {
        var manual = entityHeader(.device, capturedAt: 1, count: 2)
        manual.append(componentTag(0xffff, .float32))
        withUnsafeBytes(of: Float(59.9).bitPattern.littleEndian) {
            manual.append(contentsOf: $0)
        }
        manual.append(componentTag(Component.ID.fps.rawValue, .float32))
        withUnsafeBytes(of: Float(28.4).bitPattern.littleEndian) {
            manual.append(contentsOf: $0)
        }

        let frames = try FrameReader.frames(in: encoder.frame(manual))
        guard case .entity(let decoded) = frames[0] else {
            Issue.record("expected an entity frame")
            return
        }

        #expect(decoded.components[0].known == nil)
        #expect(decoded.components[0].value == .float32(59.9))
        #expect(decoded.components[1].known == .fps)
        #expect(decoded.components[1].value == .float32(28.4))
    }

    @Test func readsTheManifestFrame() throws {
        let advertised = [
            AdvertisedInstrument(id: 1, emits: [12]),
            AdvertisedInstrument(id: 2, emits: [7, 8, 9]),
        ]

        let frames = try FrameReader.frames(in: encoder.frame(encoder.hello(advertised)))

        guard case .manifest(let decoded) = frames[0] else {
            Issue.record("expected a manifest frame")
            return
        }

        #expect(decoded == advertised)
    }

    @Test func anUnknownPayloadKindIsRefusedRatherThanGuessed() {
        #expect(throws: DecoderError.unknownPayloadKind(99)) {
            try FrameReader.frames(in: encoder.frame(Data([99, 0, 0])))
        }
    }

    @Test func walksManyFramesInOrder() throws {
        let entities = (0 ..< 5).map { index -> Entity in
            var entity = Entity(.process, capturedAt: UInt64(index))
            entity.add(.memoryUsedBytes(UInt64(index) * 1024))
            return entity
        }

        let frames = try FrameReader.frames(in: framed(entities))

        #expect(frames.count == 5)
        #expect(frames.compactMap { frame -> UInt64? in
            guard case .entity(let decoded) = frame else {
                return nil
            }

            return decoded.capturedAt
        } == [0, 1, 2, 3, 4])
    }

    @Test func aStreamCutMidFrameIsRefusedRatherThanGuessed() {
        var entity = Entity(.device, capturedAt: 1)
        entity.add(.fps(60))
        let complete = framed([entity])

        for cut in 1 ..< complete.count {
            #expect(throws: (any Error).self) {
                try FrameReader.frames(in: complete.prefix(cut))
            }
        }
    }

    @Test func anEmptyBufferYieldsNoFrames() throws {
        #expect(try FrameReader.frames(in: Data()).isEmpty)
    }

    /// Past the limit, a caller belongs on `next()` instead of holding every frame at once.
    @Test func moreFramesThanTheLimitAreRefusedRatherThanRetainedUnbounded() throws {
        let entities = (0 ..< 5).map { Entity(.process, capturedAt: UInt64($0)) }
        let data = framed(entities)

        #expect(throws: DecoderError.tooManyFrames(4)) {
            try FrameReader.frames(in: data, limit: 4)
        }

        let frames = try FrameReader.frames(in: data, limit: 5)
        #expect(frames.count == 5)
    }

    /// A negative limit is refused outright, not only when there happens to be a frame to hit it.
    @Test func aNegativeLimitIsRefusedEvenAgainstEmptyData() {
        #expect(throws: DecoderError.tooManyFrames(-1)) {
            try FrameReader.frames(in: Data(), limit: -1)
        }
    }

    /// A count is a claim about bytes not there — believing it reserves memory unsent.
    @Test func acomponentCountLargerThanTheFrameIsRefusedRatherThanReserved() {
        var manual = Data([PayloadKind.entity.rawValue])
        withUnsafeBytes(of: Entity.ID.device.rawValue.littleEndian) {
            manual.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt64(1).littleEndian) { manual.append(contentsOf: $0) }
        manual.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff,
                                   0xff, 0xff, 0xff, 0xff, 0x01])

        #expect(throws: DecoderError.truncated) {
            try FrameReader.frames(in: encoder.frame(manual))
        }
    }

    @Test func amanifestCountLargerThanTheFrameIsRefusedRatherThanReserved() {
        var manual = Data([PayloadKind.manifest.rawValue])
        manual.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff,
                                   0xff, 0xff, 0xff, 0xff, 0x01])

        #expect(throws: DecoderError.truncated) {
            try FrameReader.frames(in: encoder.frame(manual))
        }
    }

    /// A string cut past the ceiling must land on a character boundary, not mid-UTF-8.
    @Test func astringTooLongToFitIsCutOnACharacterBoundary() throws {
        var entity = Entity(.device, capturedAt: 1)
        entity.add(.deviceModel(String(repeating: "é", count: 200)))

        let frames = try FrameReader.frames(in: encoder.frame(encoder.encode(entity)))

        guard case .entity(let decoded) = frames[0],
              case .string(let text) = decoded.components[0].value
        else {
            Issue.record("expected a string component")
            return
        }

        #expect(text == String(repeating: "é", count: 127))
        #expect(text.utf8.count == 254)
    }

    private func framed(_ entities: [Entity]) -> Data {
        var out = Data()
        for entity in entities {
            out.append(encoder.frame(encoder.encode(entity)))
        }
        return out
    }

    private func entityHeader(_ id: Entity.ID, capturedAt: UInt64,
                              count: UInt8) -> Data
    {
        var out = Data([PayloadKind.entity.rawValue])
        withUnsafeBytes(of: id.rawValue.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: capturedAt.littleEndian) { out.append(contentsOf: $0) }
        out.append(count)
        return out
    }

    private func componentTag(_ id: UInt16, _ scalar: Scalar) -> Data {
        var out = Data()
        withUnsafeBytes(of: id.littleEndian) { out.append(contentsOf: $0) }
        out.append(scalar.rawValue)
        return out
    }

    private func encodedValue(_ value: ComponentValue) -> Data {
        var out = Data()
        switch value {
        case .int8(let v): out.append(UInt8(bitPattern: v))
        case .int16(let v): withUnsafeBytes(of: UInt16(bitPattern: v).littleEndian) {
                out.append(contentsOf: $0)
            }
        case .int32(let v): withUnsafeBytes(of: UInt32(bitPattern: v).littleEndian) {
                out.append(contentsOf: $0)
            }
        case .int64(let v): withUnsafeBytes(of: UInt64(bitPattern: v).littleEndian) {
                out.append(contentsOf: $0)
            }
        case .uint8(let v): out.append(v)
        case .uint16(let v): withUnsafeBytes(of: v.littleEndian) {
                out.append(contentsOf: $0)
            }
        case .uint32(let v): withUnsafeBytes(of: v.littleEndian) {
                out.append(contentsOf: $0)
            }
        case .uint64(let v): withUnsafeBytes(of: v.littleEndian) {
                out.append(contentsOf: $0)
            }
        case .float32(let v): withUnsafeBytes(of: v.bitPattern.littleEndian) {
                out.append(contentsOf: $0)
            }
        case .float64(let v): withUnsafeBytes(of: v.bitPattern.littleEndian) {
                out.append(contentsOf: $0)
            }
        case .bool(let v): out.append(v ? 1 : 0)
        case .string(let v):
            let utf8 = Array(v.utf8.prefix(255))
            out.append(UInt8(utf8.count))
            out.append(contentsOf: utf8)
        }
        return out
    }
}
