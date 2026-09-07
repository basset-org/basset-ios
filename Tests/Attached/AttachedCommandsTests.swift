@testable import BassetAttached
import BassetEntityComponent
import Foundation
import Testing

struct AttachedCommandsTests {
    @Test func aCommandEnvelopeIsToldApartFromDesiredState() {
        let command = Data(#"{"command":{"id":7,"name":"tap","arguments":{"x":12.5,"y":40}}}"#.utf8)
        let desired = Data(#"{"ingest_endpoint":"x","requests":[]}"#.utf8)

        let decoded = AttachedCommand.decode(command)
        #expect(decoded?.id == 7)
        #expect(decoded?.name == "tap")
        #expect(decoded?.point() == CGPoint(x: 12.5, y: 40))
        #expect(AttachedCommand.decode(desired) == nil)
    }

    @Test func anUnknownCommandAnswersWithItsIdAndAStatus() async throws {
        let frames = await AttachedCommands.frames(
            answering: AttachedCommand(id: 9, name: "dance", arguments: [:])
        )

        #expect(frames.count == 1)
        let decoded = try FrameReader.frames(in: frames[0])
        guard case .entity(let entity)? = decoded.first else {
            Issue.record("no entity in the answer")
            return
        }

        #expect(entity.known == .command)
        #expect(entity.components.contains { $0.known == .commandId && $0.value == .uint32(9) })
        #expect(entity.components.contains {
            $0.known == .mechanismStatus && $0.value == .string("unknown command: dance")
        })
    }
}
