@testable import Basset
import BassetECS
import Foundation
import Testing

struct EncoderTests {
    private let encoder: FrameEncoder = .init()

    /// kind(1) + entity id(2) + capturedAt(8) = 11 bytes before the count.
    private let headerWidth = 11

    @Test func entityCarriesItsKindIdAndCaptureTimestamp() {
        var device = Entity(.device, capturedAt: 0x0102030405060708)
        device.add(.fps(60))

        let payload = encoder.encode(device)

        #expect(Array(payload.prefix(headerWidth)) == [
            PayloadKind.entity.rawValue,
            Entity.ID.device.rawValue.littleBytes.0,
            Entity.ID.device.rawValue.littleBytes.1,
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        ])
        #expect(payload[headerWidth] == 1)
    }

    @Test func everyComponentIsTaggedWithItsScalar() {
        var device = Entity(.device, capturedAt: 0)
        device.add(.memoryUsedBytes(4096))
        device.add(.deviceModel("iPhone17,2"))

        let components = encoder.encode(device).dropFirst(headerWidth + 1)

        #expect(Array(components) == [
            Component.ID.memoryUsedBytes.rawValue.littleBytes.0,
            Component.ID.memoryUsedBytes.rawValue.littleBytes.1,
            Scalar.uint64.rawValue,
            0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            Component.ID.deviceModel.rawValue.littleBytes.0,
            Component.ID.deviceModel.rawValue.littleBytes.1,
            Scalar.string.rawValue,
            10,
        ] + Array("iPhone17,2".utf8))
    }

    @Test func entityWithNoComponentsEndsAfterItsCount() {
        let payload = encoder.encode(Entity(.device, capturedAt: 0))

        #expect(payload.count == headerWidth + 1)
        #expect(payload[headerWidth] == 0)
    }

    /// A leading kind byte, not inferred — entity id 256's low byte reads as zero.
    @Test func aKindByteSaysWhichPayloadThisIs() {
        let manifest = encoder.hello([AdvertisedInstrument(id: 1, emits: [12])])
        let entity = encoder.encode(Entity(.device, capturedAt: 0))

        #expect(manifest[manifest.startIndex] == PayloadKind.manifest.rawValue)
        #expect(entity[entity.startIndex] == PayloadKind.entity.rawValue)
    }

    @Test func captureTimestampAdvancesWithTheWallClock() {
        let before = UInt64(Date().timeIntervalSince1970 * 1000000)
        let captured = Entity(.device).capturedAt
        let after = UInt64(Date().timeIntervalSince1970 * 1000000)

        #expect(captured >= before - 1000)
        #expect(captured <= after + 1000)
    }

    @Test func boolRidesTheWireAsASingleByte() {
        var session = Entity(.captureSession, capturedAt: 0)
        session.add(.sessionRunning(true))
        session.add(.sessionInterrupted(false))

        let components = Array(encoder.encode(session).dropFirst(headerWidth + 1))

        #expect(components.count == 2 * (2 + 1 + 1))
        #expect(components[3] == 1)
        #expect(components[7] == 0)
    }
}

extension UInt16 {
    var littleBytes: (UInt8, UInt8) {
        (UInt8(self & 0xff), UInt8(self >> 8))
    }
}
