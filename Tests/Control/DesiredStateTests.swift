@testable import Basset
import Foundation
import Testing

struct TimestampTests {
    /// The control plane can send 6 fractional digits; the formatter's option wants 3.
    @Test func aPostgresTimestampWithMicrosecondsParses() throws {
        let parsed = try #require(Timestamps.parse("2026-07-28T13:49:12.410488Z"))
        let whole = try #require(Timestamps.parse("2026-07-28T13:49:12Z"))
        #expect(abs(parsed.timeIntervalSince(whole)) < 1)
    }

    @Test func milliseconds_and_wholeSeconds_bothParse() {
        #expect(Timestamps.parse("2026-07-28T13:49:12.410Z") != nil)
        #expect(Timestamps.parse("2026-07-28T13:49:12Z") != nil)
    }

    @Test func somethingThatIsNotATimestampIsRefused() {
        #expect(Timestamps.parse("soon") == nil)
        #expect(Timestamps.parse("") == nil)
    }
}

struct RejectionBackoffTests {
    /// A token's expiry is unknown ahead, so the first rejection costs one round trip.
    @Test func theFirstRejectionAfterAnAnswerWaitsForNothing() {
        #expect(DeviceLoop.rejectionDelay(afterConsecutive: 0) == nil)
    }

    /// A revoked key is refused instantly — without backoff, retries hit network speed.
    @Test func aCredentialThatKeepsBeingRefusedIsAskedForLessOften() {
        let delays = (1...4).map { DeviceLoop.rejectionDelay(afterConsecutive: $0) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    /// Capped at a minute — long enough to back off, short enough to notice a fix.
    @Test func theWaitStopsGrowingAtAMinute() {
        #expect(DeviceLoop.rejectionDelay(afterConsecutive: 7) == .seconds(60))
        #expect(DeviceLoop.rejectionDelay(afterConsecutive: 5000) == .seconds(60))
    }
}

struct DesiredStateDecodingTests {
    @Test func arealCtrlResponseDecodes() throws {
        let response = try decode(
            """
            {"device_token":"device.jwt","ingest_endpoint":"in.basset.dev",
             "requests":[{"request_id":2,"instruments":["runtime.memory","device.info"],
             "at_launch":false,"expires_at":"2026-07-28T13:49:12.410488Z",
             "max_frames":500,"request_token":"request.jwt"}]}
            """
        )

        #expect(response.deviceToken == "device.jwt")
        #expect(response.ingestEndpoint == "in.basset.dev")
        #expect(response.requests.count == 1)

        let request = try #require(response.requests.first)
        #expect(request.requestId == 2)
        #expect(request.instruments == ["runtime.memory", "device.info"])
        #expect(request.maxFrames == 500)
        #expect(request.requestToken == "request.jwt")
    }

    @Test func aRequestWithoutMaxFramesIsBackstopped() throws {
        let response = try decode(
            """
            {"device_token":"d","ingest_endpoint":"in","requests":[
             {"request_id":7,"instruments":["ui.fps"],"at_launch":true,
              "expires_at":"2026-07-28T13:49:12Z","request_token":"r"}]}
            """
        )

        let request = try #require(response.requests.first)
        #expect(request.maxFrames == BassetRequest.maximumFrames)
        #expect(request.atLaunch)
    }

    /// A control plane cannot ask for more frames than the device will ever stream.
    @Test func anOversizedMaxFramesIsClampedToTheBackstop() throws {
        let response = try decode(
            """
            {"device_token":"d","ingest_endpoint":"in","requests":[
             {"request_id":8,"instruments":["ui.fps"],
              "expires_at":"2026-07-28T13:49:12Z","max_frames":4000000000,
              "request_token":"r"}]}
            """
        )

        let request = try #require(response.requests.first)
        #expect(request.maxFrames == BassetRequest.maximumFrames)
    }

    /// A far-future expiry cannot pin instruments hot for longer than the backstop.
    @Test func aFarFutureExpiryIsClampedToTheLifetimeHorizon() throws {
        let response = try decode(
            """
            {"device_token":"d","ingest_endpoint":"in","requests":[
             {"request_id":9,"instruments":["ui.fps"],
              "expires_at":"3000-01-01T00:00:00Z","request_token":"r"}]}
            """
        )

        let request = try #require(response.requests.first)
        let horizon = Date(timeIntervalSinceNow: BassetRequest.maximumLifetime)
        #expect(request.expiresAt <= horizon.addingTimeInterval(5))
    }

    /// A request that fits inside both backstops is carried through untouched.
    @Test func aRequestWithinTheBackstopsKeepsItsValues() throws {
        let response = try decode(
            """
            {"device_token":"d","ingest_endpoint":"in","requests":[
             {"request_id":10,"instruments":["ui.fps"],
              "expires_at":"2026-07-28T13:49:12Z","max_frames":500,
              "request_token":"r"}]}
            """
        )

        let request = try #require(response.requests.first)
        #expect(request.maxFrames == 500)
        #expect(request.expiresAt == Timestamps.parse("2026-07-28T13:49:12Z"))
    }

    @Test func anEmptyDesiredStateIsAValidAnswer() throws {
        let response =
            try decode(#"{"device_token":"d","ingest_endpoint":"in","requests":[]}"#)
        #expect(response.requests.isEmpty)
    }

    private func decode(_ json: String) throws -> DeviceResponse {
        try JSONDecoder().decode(DeviceResponse.self, from: Data(json.utf8))
    }
}

struct AtLaunchRequestTests {
    @Test func onlyAtLaunchRequestsAreKept() {
        let store = scratch()
        store.save([
            request(1, atLaunch: true, expiresIn: 600),
            request(2, atLaunch: false, expiresIn: 600),
        ])

        #expect(store.load().map(\.requestId) == [1])
    }

    /// A request is an instruction, not a credential — no multi-day bearer token on disk.
    @Test func aTokenNeverReachesDisk() {
        let store = scratch()
        store.save([request(1, atLaunch: true, expiresIn: 600)])

        #expect(store.load().first?.requestToken == nil)
    }

    @Test func anExpiredRequestIsNotActivatedOnTheNextLaunch() {
        let store = scratch()
        store.save([request(1, atLaunch: true, expiresIn: -60)])

        #expect(store.load().isEmpty)
    }

    @Test func savingNothingClearsWhatWasThere() {
        let store = scratch()
        store.save([request(1, atLaunch: true, expiresIn: 600)])
        store.save([])

        #expect(store.load().isEmpty)
    }

    private func scratch() -> AtLaunchRequests {
        AtLaunchRequests(
            storage: UserDefaults(suiteName: "basset-tests-\(UUID().uuidString)")!
        )
    }

    private func request(
        _ id: UInt64,
        atLaunch: Bool,
        expiresIn seconds: TimeInterval,
        token: String? = "request-token"
    ) -> BassetRequest {
        BassetRequest(
            requestId: id,
            instruments: ["runtime.memory"],
            atLaunch: atLaunch,
            expiresAt: Date().addingTimeInterval(seconds),
            maxFrames: nil,
            requestToken: token
        )
    }
}

/// One malformed request from the control plane must not cost the requests beside it.
struct LenientRequestListTests {
    @Test func aMalformedRequestIsSkippedRatherThanFailingTheRest() throws {
        let json = """
        {"requests": [
            {"request_id": 1, "instruments": ["a"], "expires_at": "2026-07-28T13:49:12Z"},
            {"request_id": "not a number"},
            {"request_id": 2, "instruments": ["b"], "expires_at": "2026-07-28T13:49:12Z"}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            RequestsResponse.self,
            from: Data(json.utf8)
        )
        #expect(decoded.requests.map(\.requestId) == [1, 2])
    }

    @Test func garbageElementsOfEveryShapeDecodeToNothing() throws {
        let json = """
        {"requests": ["soon", 4, null, {}, [true]]}
        """
        let decoded = try JSONDecoder().decode(
            RequestsResponse.self,
            from: Data(json.utf8)
        )
        #expect(decoded.requests.isEmpty)
    }

    @Test func aNullElementDoesNotTruncateWhatFollowsIt() throws {
        let json = """
        {"requests": [
            null,
            {"request_id": 3, "instruments": ["c"], "expires_at": "2026-07-28T13:49:12Z"}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            RequestsResponse.self,
            from: Data(json.utf8)
        )
        #expect(decoded.requests.map(\.requestId) == [3])
    }

    @Test func aMissingListReadsAsEmpty() throws {
        let decoded = try JSONDecoder().decode(
            RequestsResponse.self,
            from: Data("{}".utf8)
        )
        #expect(decoded.requests.isEmpty)
    }
}
