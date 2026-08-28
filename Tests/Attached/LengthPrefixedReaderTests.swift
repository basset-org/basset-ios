@testable import BassetAttached
import Foundation
import Testing

#if DEBUG
struct LengthPrefixedReaderTests {
    @Test func aDocumentSplitAcrossReadsIsHeldUntilItIsWhole() throws {
        var reader = LengthPrefixedReader()
        let whole = framed("{\"a\":1}")

        reader.append(whole.prefix(3))
        #expect(try reader.next() == nil)

        reader.append(whole.dropFirst(3).prefix(2))
        #expect(try reader.next() == nil)

        reader.append(whole.dropFirst(5))
        #expect(try reader.next() == Data("{\"a\":1}".utf8))
        #expect(try reader.next() == nil)
    }

    @Test func twoDocumentsInOneReadAreBothReturned() throws {
        var reader = LengthPrefixedReader()
        reader.append(framed("one") + framed("two"))

        #expect(try reader.next() == Data("one".utf8))
        #expect(try reader.next() == Data("two".utf8))
        #expect(try reader.next() == nil)
    }

    @Test func anEmptyDocumentIsADocumentRatherThanTheEndOfTheStream() throws {
        var reader = LengthPrefixedReader()
        reader.append(framed("") + framed("after"))

        #expect(try reader.next() == Data())
        #expect(try reader.next() == Data("after".utf8))
    }

    @Test func aLengthPastTheBoundIsRefusedRatherThanBuffered() {
        var reader = LengthPrefixedReader()
        reader.append(Data([0x7f, 0xff, 0xff, 0xff]))

        #expect(throws: (any Error).self) {
            try reader.next()
        }
    }

    @Test func nothingIsConsumedWhileADocumentIsIncomplete() throws {
        var reader = LengthPrefixedReader()
        reader.append(framed("held").prefix(6))

        _ = try reader.next()
        #expect(reader.buffered.count == 6)
    }

    private func framed(_ text: String) -> Data {
        let body = Data(text.utf8)
        var out = Data([
            UInt8((body.count >> 24) & 0xff),
            UInt8((body.count >> 16) & 0xff),
            UInt8((body.count >> 8) & 0xff),
            UInt8(body.count & 0xff),
        ])
        out.append(body)
        return out
    }
}
#endif
