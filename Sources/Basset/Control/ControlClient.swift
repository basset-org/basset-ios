import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ControlError: Error {
    case unauthorized
    case refused(status: Int)
    case notHTTP
}

struct ControlClient: Sendable {
    let endpoint: URL
    let apiKey: String

    private let session: URLSession

    init(endpoint: URL, apiKey: String, hold: TimeInterval = 35) {
        self.endpoint = endpoint
        self.apiKey = apiKey

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = hold
        configuration.waitsForConnectivity = true
        self.session = URLSession(
            configuration: configuration,
            delegate: RedirectRefusal.shared,
            delegateQueue: nil
        )

        IgnoredSessions.remember(session)
    }

    func putDevice(_ identity: DeviceIdentity,
                   userId: String?) async throws -> DeviceResponse
    {
        var body: [String: String] = [
            "api_key": apiKey,
            "device_id": identity.deviceId,
            "model": identity.model,
            "os": identity.os,
            "app_version": identity.appVersion,
            "build_configuration": identity.buildConfiguration,
            "device_kind": identity.deviceKind,
        ]
        if let bundleId = identity.bundleId, !bundleId.isEmpty {
            body["bundle_id"] = bundleId
        }
        if let userId, !userId.isEmpty {
            body["user_id"] = userId
        }

        var request = URLRequest(url: endpoint.appendingPathComponent("device"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(to: request)
        return try JSONDecoder().decode(DeviceResponse.self, from: data)
    }

    func requests(deviceToken: String) async throws -> [BassetRequest] {
        var request = URLRequest(url: endpoint.appendingPathComponent("requests"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "authorization")

        let data = try await send(to: request)
        return try JSONDecoder().decode(RequestsResponse.self, from: data).requests
    }

    private func send(to request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ControlError.notHTTP
        }
        guard http.statusCode != 401 else {
            throw ControlError.unauthorized
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ControlError.refused(status: http.statusCode)
        }

        return data
    }
}
