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

    @Test func runningOutOfPortsSaysSoRatherThanFailingQuietly() {
        // How much of the range is already taken depends on what else is running on
        // this machine, so open until one is refused rather than assuming ten are free.
        var held = [AttachedLink]()
        defer { held.forEach { $0.stop() } }

        var refusal: (any Error)?
        for _ in 0...BassetAttached.portsToTry {
            do {
                try held.append(AttachedLink())
            } catch {
                refusal = error
                break
            }
        }

        #expect(refusal is BassetAttached.Failure)
    }
}
#endif

@Suite(.serialized)
struct AttachedBridgeOrderTests {
    @Test func stateArrivingBeforeStartDoesNotWedgeTheLaunch() throws {
        AttachedBridge.close()
        try AttachedBridge.apply(desiredState("cpu.thread.usage"))

        // start holds a lock that converge takes again, so replaying pending state
        // under it deadlocks the thread an app launches on. Nothing here asserts a
        // value: the failure this covers is start never returning at all.
        let settled = DispatchSemaphore(value: 0)
        let outcome = NSLock()
        var returned = false

        Thread.detachNewThread {
            // Loopback, never ctrl.basset.dev: the loop this starts polls forever and
            // nothing stops it, so a default config would point a test suite at
            // production for the life of the process.
            Basset.start(Config(
                apiKey: "bk_attached_test",
                control: URL(string: "https://127.0.0.1:1")!
            ))
            outcome.withLock { returned = true }
            settled.signal()
        }
        _ = settled.wait(timeout: .now() + 5)
        let answered = outcome.withLock { returned }

        // Torn down only when start returned. The failure this guards leaves the lock
        // held on the detached thread, and stopForTesting waits on that lock — so
        // tearing down unconditionally would wedge the suite instead of failing here.
        if answered {
            Basset.stopForTesting()
        }

        #expect(answered, "Basset.start did not return, so a launch would hang")
    }

    @Test func convergingUnderTheBridgeCanStillReadTheChannel() {
        // Convergence runs under this lock and reaches back through IngestTransports
        // to read `channel` on the same thread, which a plain NSLock deadlocks on —
        // and only when a request has frames waiting, so nothing else here catches it.
        let settled = DispatchSemaphore(value: 0)
        let outcome = NSLock()
        var returned = false

        Thread.detachNewThread {
            AttachedBridge.whileNothingIsAttached {
                _ = AttachedBridge.channel
            }
            outcome.withLock { returned = true }
            settled.signal()
        }
        _ = settled.wait(timeout: .now() + 5)

        #expect(
            outcome.withLock { returned },
            "reading the channel from under the bridge deadlocked"
        )
    }

    @Test func aDocumentThatIsNotDesiredStateIsRefused() {
        #expect(throws: (any Error).self) {
            try AttachedBridge.apply(Data("not a desired state".utf8))
        }
    }

    /// Nothing is live without a running loop, so the second frame names only itself.
    @Test func identitySendsDeviceInfoThenTheDefaultRelevantSet() throws {
        Basset.stopForTesting()

        let frames = AttachedBridge.identity()
        #expect(frames.count == 2)

        let decoded = try FrameReader.frames(in: frames.reduce(Data(), +))
        guard decoded.count == 2,
              case .entity(let device) = decoded[0],
              case .entity(let relevant) = decoded[1]
        else {
            Issue.record("expected two entity frames, got \(decoded)")
            return
        }

        #expect(device.known == .device)
        #expect(relevant.known == .relevantInstruments)

        let instrumentIds: [UInt16] = relevant.components.compactMap { component in
            guard component.known == .instrument, case .uint16(let value) = component.value
            else {
                return nil
            }

            return value
        }
        #expect(instrumentIds == [InstrumentID.instrumentsRelevant.rawValue])
    }

    private func desiredState(_ instrument: String) -> Data {
        Data("""
        {"ingest_endpoint":"attached","state_version":"v1","requests":[
          {"request_id":1,"instruments":["\(instrument)"],"at_launch":false,
           "expires_at":"2099-01-01T00:00:00Z","request_token":"attached"}]}
        """.utf8)
    }
}
