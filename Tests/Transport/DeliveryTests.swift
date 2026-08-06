@testable import Basset
import Foundation
import Testing

/// Answers that only arrive on a bad network, driven here instead: a handover
/// that kills a POST, a far end that has had enough, and a token that expired.
private final class StubbedResponses: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var answers: [(status: Int?, error: Bool)] = []
    private nonisolated(unsafe) static var attempts = 0
    private nonisolated(unsafe) static var asked: [String] = []
    private nonisolated(unsafe) static var redirectTarget: String?
    private static let lock: NSLock = .init()

    static var seen: Int {
        lock.withLock { attempts }
    }

    /// Every host the session actually dialled, in order. A redirect that is
    /// followed shows up here as a second one.
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

        if let target = Self.target, let moved = URL(string: target) {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: answer.status ?? 302,
                httpVersion: "HTTP/2",
                headerFields: ["Location": target]
            )!
            var next = request
            next.url = moved
            // Offered and then answered anyway, which is what a transport does:
            // the session asks its delegate whether to take the redirect, and
            // the 3xx is the response when the delegate says no.
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

private func stubbedChannel() -> HTTP2Channel {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubbedResponses.self]
    return HTTP2Channel(
        endpoint: URL(string: "https://in.example/frames")!,
        token: "t",
        session: URLSession(
            configuration: configuration,
            delegate: RedirectRefusal.shared,
            delegateQueue: nil
        )
    )
}

private func settle(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

@Suite(.serialized)
struct DeliveryTests {
    /// The handover case. A POST lost to a connection dying used to take its
    /// batch with it, silently — and the readings worth having are exactly the
    /// ones taken while the network was misbehaving.
    @Test func abatchLostToADeadConnectionIsSentAgain() async {
        StubbedResponses.reset([(nil, true), (200, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))
        await settle(2500)

        #expect(StubbedResponses.seen >= 2, "the failure was retried")
        #expect(channel.dropped == 0, "and nothing was written off")
    }

    /// max_readings is a cap the request asked for, so what it turns away is
    /// counted rather than retried forever.
    @Test func arefusalStopsTheChannelAndIsCounted() async {
        StubbedResponses.reset([(429, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))
        await settle(1000)

        #expect(channel.refused == "max_frames")
        #expect(channel.dropped >= 1, "the batch it was carrying is gone")
    }

    /// A 4xx this client cannot fix by asking again is written off rather than
    /// retried into a loop.
    @Test func apermanentRefusalIsNotRetried() async {
        StubbedResponses.reset([(400, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))
        await settle(1000)

        #expect(channel.dropped == 1)
        #expect(StubbedResponses.seen == 1, "asked once")
    }

    /// Every POST carries the request token, and a followed redirect would hand
    /// it to whatever host the answer named — a token that can write readings,
    /// given to somewhere the device was never told to talk to.
    @Test func aredirectIsNotFollowedAndTheTokenGoesNowhereElse() async {
        StubbedResponses.reset(
            [(302, false)],
            redirectingTo: "https://elsewhere.example/frames"
        )
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))
        await settle(1500)

        #expect(StubbedResponses.hostsAsked == ["in.example"])
        #expect(channel.dropped == 1, "the batch is written off, not re-aimed")
    }

    /// A token expiring is not a reason to lose a reading: the next PUT /device
    /// mints a fresh one.
    @Test func anexpiredTokenKeepsTheBatch() async {
        StubbedResponses.reset([(401, false), (200, false)])
        let channel = stubbedChannel()

        channel.send(Data([1, 2, 3]))
        await settle(2500)

        #expect(channel.dropped == 0)
        #expect(StubbedResponses.seen >= 2)
    }
}
