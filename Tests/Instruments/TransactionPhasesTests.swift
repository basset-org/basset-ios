@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct TransactionPhasesTests {
    /// The same four-second request, three investigations — only the breakdown says which one.
    @Test func fourSecondsInDnsIsADifferentFindingFromFourSecondsOfServerTime() {
        let slowResolver = phases(dns: 0 ..< 4, connect: 4 ..< 4.1, server: 4.2 ..< 4.3)
        let slowServer = phases(
            dns: 0 ..< 0.01,
            connect: 0.01 ..< 0.1,
            server: 0.2 ..< 4.2
        )

        #expect(near(slowResolver.dns, 4000000000))
        #expect(near(slowServer.dns, 10000000))
        #expect(near(slowServer.server, 4000000000))
    }

    /// The handshake sits inside the connect window — counting connect whole double-counts it.
    @Test func theHandshakeIsNotCountedTwiceAgainstTheConnect() {
        let measured = TransactionPhases(
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: at(0), connectEnd: at(1),
            secureConnectionStart: at(0.4), secureConnectionEnd: at(1),
            requestEnd: nil, responseStart: nil, responseEnd: nil
        )

        #expect(near(measured.tls, 600000000))
        #expect(near(measured.connect, 400000000))
    }

    /// Zeroes would say a reused connection's skipped phases were instantaneous rather than absent.
    @Test func aReusedConnectionReportsNoPhasesRatherThanZeroes() {
        let reused = TransactionPhases(
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestEnd: at(0), responseStart: at(0.25), responseEnd: at(0.3)
        )

        #expect(reused.dns == nil)
        #expect(reused.connect == nil)
        #expect(reused.tls == nil)
        #expect(near(reused.server, 250000000))
    }

    /// An unsigned subtraction on a backwards pair wraps to an eighteen-quintillion-ns phase.
    @Test func timestampsThatRunBackwardsAreRefusedRatherThanWrapped() {
        let backwards = TransactionPhases(
            domainLookupStart: at(5), domainLookupEnd: at(1),
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestEnd: nil, responseStart: nil, responseEnd: nil
        )

        #expect(backwards.dns == nil)
    }

    /// Contradictory framework data — clamped to zero rather than wrapped, same reason as above.
    @Test func aHandshakeLongerThanItsConnectClampsRatherThanWrapping() {
        let contradictory = TransactionPhases(
            domainLookupStart: nil, domainLookupEnd: nil,
            connectStart: at(0), connectEnd: at(0.2),
            secureConnectionStart: at(0), secureConnectionEnd: at(0.9),
            requestEnd: nil, responseStart: nil, responseEnd: nil
        )

        #expect(contradictory.connect == 0)
    }

    @Test func onlyThePhasesThatHappenedAreWritten() {
        var out = Readings(.networkTask)
        phases(dns: 0 ..< 0.05, connect: 0.05 ..< 0.1, server: 0.1 ..< 0.2)
            .write(into: &out)

        #expect(out.build().componentIDs.contains(.dnsNanoseconds))
        #expect(out.build().componentIDs.contains(.responseNanoseconds) == false)
    }

    /// `Date` is a `Double` of seconds — nanosecond conversion lands a few tens of ns off.
    private func near(
        _ measured: UInt64?,
        _ expected: UInt64,
        within tolerance: UInt64 = 1000
    ) -> Bool {
        guard let measured else {
            return false
        }

        return measured > expected - tolerance && measured < expected + tolerance
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func phases(
        dns: Range<TimeInterval>,
        connect: Range<TimeInterval>,
        server: Range<TimeInterval>
    ) -> TransactionPhases {
        TransactionPhases(
            domainLookupStart: at(dns.lowerBound), domainLookupEnd: at(dns.upperBound),
            connectStart: at(connect.lowerBound), connectEnd: at(connect.upperBound),
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestEnd: at(server.lowerBound), responseStart: at(server.upperBound),
            responseEnd: nil
        )
    }
}

extension TransactionPhasesTests {
    /// CFNetwork's dates are taken on trust; an infinite pair must refuse, not trap.
    @Test func anInfiniteIntervalIsRefusedRatherThanTrapped() {
        let phases = TransactionPhases(
            domainLookupStart: Date(timeIntervalSinceReferenceDate: 0),
            domainLookupEnd: Date(timeIntervalSinceReferenceDate: .infinity),
            connectStart: nil, connectEnd: nil,
            secureConnectionStart: nil, secureConnectionEnd: nil,
            requestEnd: nil, responseStart: nil, responseEnd: nil
        )

        #expect(phases.dns == nil)
    }
}
