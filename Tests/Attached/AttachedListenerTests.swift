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
