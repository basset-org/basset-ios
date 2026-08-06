@testable import Basset
import Foundation
import Testing

struct TimestampTests {
    /// What ctrl actually sends: Postgres renders microseconds, and
    /// ISO8601DateFormatter's fractional-seconds option accepts exactly three
    /// digits. Getting this wrong rejects every response.
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

    @Test func anUncappedRequestDecodesWithoutMaxFrames() throws {
        let response = try decode(
            """
            {"device_token":"d","ingest_endpoint":"in","requests":[
             {"request_id":7,"instruments":["ui.fps"],"at_launch":true,
              "expires_at":"2026-07-28T13:49:12Z","request_token":"r"}]}
            """
        )

        let request = try #require(response.requests.first)
        #expect(request.maxFrames == nil)
        #expect(request.atLaunch)
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

    /// A request is an instruction, not a credential: a token on disk would be a
    /// multi-day bearer credential sitting in UserDefaults.
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
