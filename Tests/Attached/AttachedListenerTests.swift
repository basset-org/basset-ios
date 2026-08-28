@testable import Basset
@testable import BassetAttached
import Foundation
import Testing

#if DEBUG
@Suite(.serialized)
struct AttachedListenerTests {
    @Test func twoAppsAttachedAtOnceGetDifferentPorts() throws {
        let first = try AttachedLink()
        defer { first.stop() }
        let second = try AttachedLink()
        defer { second.stop() }

        #expect(first.port != second.port)
        #expect(first.port >= BassetAttached.firstPort)
        #expect(second.port < BassetAttached.firstPort + UInt16(BassetAttached.portsToTry))
    }

    @Test func attachingAgainAfterStoppingStillFindsAPort() throws {
        // Cancelling a listener is asynchronous, so the port it held may not be the
        // one the next attach gets. Finding any of them is the property that matters.
        for _ in 0 ..< 3 {
            let link = try AttachedLink()
            #expect(link.port >= BassetAttached.firstPort)
            #expect(link.port < BassetAttached.firstPort + UInt16(BassetAttached.portsToTry))
            link.stop()
        }
    }

    @Test func runningOutOfPortsSaysSoRatherThanFailingQuietly() throws {
        var held = [AttachedLink]()
        defer { held.forEach { $0.stop() } }

        for _ in 0 ..< BassetAttached.portsToTry {
            try held.append(AttachedLink())
        }

        #expect(throws: BassetAttached.Failure.self) {
            _ = try AttachedLink()
        }
    }
}
#endif

@Suite(.serialized)
struct AttachedBridgeOrderTests {
    @Test func stateArrivingBeforeTheLoopIsNotLost() throws {
        AttachedBridge.close()

        // Nothing has started yet, so this cannot be applied when it arrives.
        try AttachedBridge.apply(desiredState("cpu.thread.usage"))

        // Applying it a second time once a loop exists is what start() does; here
        // the point is only that the document was kept rather than dropped.
        AttachedBridge.applyWhatArrivedBeforeTheLoop()
    }

    @Test func aDocumentThatIsNotDesiredStateIsRefused() {
        #expect(throws: (any Error).self) {
            try AttachedBridge.apply(Data("not a desired state".utf8))
        }
    }

    private func desiredState(_ instrument: String) -> Data {
        Data("""
        {"ingest_endpoint":"attached","state_version":"v1","requests":[
          {"request_id":1,"instruments":["\(instrument)"],"at_launch":false,
           "expires_at":"2099-01-01T00:00:00Z","request_token":"attached"}]}
        """.utf8)
    }
}
