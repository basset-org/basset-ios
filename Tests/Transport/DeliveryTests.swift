@testable import Basset
import Foundation
import Testing

/// Drives bad-network answers here: a killed POST, a refusing far end, an expired token.
final class StubbedResponses: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var answers: [(status: Int?, error: Bool)] = []
    private nonisolated(unsafe) static var attempts = 0
    private nonisolated(unsafe) static var asked: [String] = []
    private nonisolated(unsafe) static var redirectTarget: String?
    private static let lock: NSLock = .init()

    static var seen: Int {
        lock.withLock { attempts }
    }

    /// Every host dialled, in order — a followed redirect shows up as a second entry.
    static var hostsAsked: [String] {
        lock.withLock { asked }
    }

    static var target: String? {
        lock.withLock { redirectTarget }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let answer = Self.next(dialling: request.url?.host ?? "")
        if answer.error {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        guard answer.status != nil else {
            // Neither an error nor a status: left hanging, as if still in flight — the
            // channel's own close() is what's expected to cancel this, same as production.
            return
        }

        if let target = Self.target, let moved = URL(string: target) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: answer.status ?? 302,
                httpVersion: "HTTP/2",
                headerFields: ["Location": target]
            )!
            var next = request
            next.url = moved
            // The session asks about the redirect; the 3xx is the answer when it says no.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.status ?? 200,
            httpVersion: "HTTP/2",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(
        _ planned: [(status: Int?, error: Bool)],
        redirectingTo target: String? = nil
    ) {
        lock.withLock {
            answers = planned
            attempts = 0
            asked = []
            redirectTarget = target
        }
    }

    static func next(dialling host: String) -> (status: Int?, error: Bool) {
        lock.withLock {
            attempts += 1
            asked.append(host)
            return answers.isEmpty ? (200, false) : answers.removeFirst()
        }
    }
}

/// A fresh directory per call, so one test's backlog file can't leak into another's.
func stubbedChannel(
    requestId: UInt64 = 1,
    backlogDirectory: URL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
) -> HTTP2Channel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubbedResponses.self]
    return HTTP2Channel(
        endpoint: URL(string: "https://in.example/frames")!,
        token: "t",
        requestId: requestId,
        session: URLSession(
            configuration: configuration,
            delegate: RedirectRefusal.shared,
            delegateQueue: nil
        ),
        backlogDirectory: backlogDirectory,
        monitorsPath: false
    )
}

@Suite(.serialized)
struct DeliveryTests {
    /// A POST lost to a dying connection used to take its batch down silently with it.
    @Test func abatchLostToADeadConnectionIsSentAgain() async {
        StubbedResponses.reset([(nil, true), (200, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))

        #expect(await eventually { StubbedResponses.seen >= 2 }, "the failure was retried")
        #expect(channel.dropped == 0, "and nothing was written off")
    }

    /// max_readings is the request's own cap; what it refuses is counted, not retried.
    @Test func arefusalStopsTheChannelAndIsCounted() async {
        StubbedResponses.reset([(429, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))

        #expect(await eventually { channel.refused == "max_frames" })
        #expect(channel.dropped >= 1, "the batch it was carrying is gone")
    }

    /// A 4xx nothing here can fix is written off rather than retried into a loop.
    @Test func apermanentRefusalIsNotRetried() async {
        StubbedResponses.reset([(400, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))

        #expect(await eventually { channel.dropped == 1 })
        #expect(StubbedResponses.seen == 1, "asked once")
    }

    /// A followed redirect would hand the request token to a host never authorised.
    @Test func aredirectIsNotFollowedAndTheTokenGoesNowhereElse() async {
        StubbedResponses.reset(
            [(302, false)],
            redirectingTo: "https://elsewhere.example/frames"
        )
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))

        #expect(await eventually { channel.dropped == 1 }, "the batch is written off")
        #expect(StubbedResponses.hostsAsked == ["in.example"], "and not re-aimed")
    }

    /// An expired token isn't a lost reading — the next poll mints a fresh one.
    @Test func anexpiredTokenKeepsTheBatch() async {
        StubbedResponses.reset([(401, false), (200, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))

        #expect(await eventually { StubbedResponses.seen >= 2 })
        #expect(channel.dropped == 0)
    }
}
