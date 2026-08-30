@testable import Basset
import Foundation
import Testing

private let identity: DeviceIdentity = .init(
    deviceId: "device",
    model: "iPhone",
    os: "18.0",
    appVersion: "1.0",
    appName: "Example",
    bundleId: "com.example.app",
    buildConfiguration: "release",
    deviceKind: "device"
)

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

final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastBody = request.httpBody
            ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else {
                        break
                    }

                    collected.append(contentsOf: buffer[0 ..< read])
                }
                return collected
            }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"ingest_endpoint":"in","requests":[],"state_version":"v1"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ControlClientBodyTests {
    @Test func aLaunchThatHoldsNothingStillCarriesAnEmptyStateVersion() async throws {
        RecordingProtocol.lastBody = nil
        _ = try await client().requests(DeviceIdentity.current(), userId: nil)

        #expect(try posted()["state_version"] == "")
    }

    @Test func theVersionTheControlPlaneIssuedIsSentBackOnTheNextPoll() async throws {
        RecordingProtocol.lastBody = nil
        _ = try await client().requests(
            DeviceIdentity.current(),
            userId: nil,
            stateVersion: "v1"
        )

        #expect(try posted()["state_version"] == "v1")
    }

    private func client() -> ControlClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        return ControlClient(
            endpoint: URL(string: "https://127.0.0.1:1")!,
            apiKey: "bk_test",
            session: URLSession(configuration: configuration)
        )
    }

    private func posted() throws -> [String: String] {
        let body = try #require(RecordingProtocol.lastBody)
        return try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
    }
}
