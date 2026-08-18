@testable import Basset
import Foundation
import Testing

private let identity: DeviceIdentity = .init(
    deviceId: "device",
    model: "iPhone",
    os: "18.0",
    appVersion: "1.0",
    bundleId: "com.example.app",
    buildConfiguration: "release",
    deviceKind: "device"
)

/// The API key never goes out over a cleartext control endpoint, even a caller-supplied one.
struct ControlClientTests {
    @Test func aNonHttpsEndpointIsRefusedBeforeAnyRequestIsSent() async throws {
        let client = try ControlClient(
            endpoint: #require(URL(string: "http://ctrl.basset.dev")),
            apiKey: "key"
        )

        do {
            _ = try await client.requests(identity, userId: nil)
            Issue.record("expected an insecureEndpoint refusal")
        } catch ControlError.insecureEndpoint {}
    }
}
