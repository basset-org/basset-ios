import BassetECS
import Foundation

/// Where a request's time actually went, from the eleven timestamps
/// `URLSessionTaskMetrics` carries and almost nobody reads.
///
/// A duration says a request took four seconds. That is not a finding — it is
/// the start of five different investigations. DNS taking four seconds is a
/// resolver problem, TLS taking four is a handshake or a certificate chain, and
/// four seconds between the request ending and the response starting is the
/// server thinking. Only the split tells them apart, and no app can obtain it
/// any other way.
///
/// Each phase is `nil` rather than zero when its timestamps are absent, which is
/// the ordinary case: a reused connection has no lookup, connect or handshake to
/// report, and reporting zeroes would say those phases were instantaneous when
/// in fact they did not happen.
struct TransactionPhases: Equatable {
    let dns: UInt64?
    let connect: UInt64?
    let tls: UInt64?
    /// Between the request finishing and the first byte of the response — the
    /// server's own time, and the only part of a slow request the app cannot fix.
    let server: UInt64?
    let response: UInt64?

    init(
        domainLookupStart: Date?, domainLookupEnd: Date?,
        connectStart: Date?, connectEnd: Date?,
        secureConnectionStart: Date?, secureConnectionEnd: Date?,
        requestEnd: Date?, responseStart: Date?, responseEnd: Date?
    ) {
        dns = Self.elapsed(from: domainLookupStart, to: domainLookupEnd)
        tls = Self.elapsed(from: secureConnectionStart, to: secureConnectionEnd)
        server = Self.elapsed(from: requestEnd, to: responseStart)
        self.response = Self.elapsed(from: responseStart, to: responseEnd)

        // The TLS handshake happens inside the connect window, so a connect that
        // reports the whole span double-counts the handshake against itself.
        // What is useful is the transport connect alone.
        let whole = Self.elapsed(from: connectStart, to: connectEnd)
        connect =
            switch (whole, tls) {
            case (let whole?, let tls?): whole > tls ? whole - tls : 0
            case (let whole?, nil): whole
            default: nil
            }
    }

    /// Timestamps that run backwards are refused rather than wrapped. These come
    /// from a framework, and an unsigned subtraction of a bad pair produces an
    /// eighteen-quintillion-nanosecond phase that reads as a finding.
    private static func elapsed(from start: Date?, to end: Date?) -> UInt64? {
        guard let start, let end else {
            return nil
        }

        let seconds = end.timeIntervalSince(start)
        guard seconds >= 0 else {
            return nil
        }

        return UInt64(seconds * 1000000000)
    }

    func write(into out: inout Readings) {
        if let dns {
            out.put(.dnsNanoseconds(dns))
        }
        if let connect {
            out.put(.connectNanoseconds(connect))
        }
        if let tls {
            out.put(.tlsNanoseconds(tls))
        }
        if let server {
            out.put(.serverNanoseconds(server))
        }
        if let response {
            out.put(.responseNanoseconds(response))
        }
    }
}

#if os(iOS)
extension TransactionPhases {
    init(_ transaction: URLSessionTaskTransactionMetrics) {
        self.init(
            domainLookupStart: transaction.domainLookupStartDate,
            domainLookupEnd: transaction.domainLookupEndDate,
            connectStart: transaction.connectStartDate,
            connectEnd: transaction.connectEndDate,
            secureConnectionStart: transaction.secureConnectionStartDate,
            secureConnectionEnd: transaction.secureConnectionEndDate,
            requestEnd: transaction.requestEndDate,
            responseStart: transaction.responseStartDate,
            responseEnd: transaction.responseEndDate
        )
    }
}

/// How the connection was secured, and over which interface it ran.
///
/// The TLS pair answers a question that otherwise needs a proxy to see: an app
/// pinned to a protocol version its server stopped accepting fails with a
/// generic error, and the negotiated version is the only thing that says so.
enum TransactionConnection {
    static func write(
        _ transaction: URLSessionTaskTransactionMetrics,
        into out: inout Readings
    ) {
        if let version = transaction.negotiatedTLSProtocolVersion {
            out.put(.tlsVersion(name(of: version)))
        }
        if let suite = transaction.negotiatedTLSCipherSuite {
            out.put(.tlsCipherSuite("0x" + String(
                suite.rawValue,
                radix: 16,
                uppercase: true
            )))
        }
        // Which interface actually carried this request, as opposed to which one
        // the path was satisfied by. `network.path.transitions` answers the
        // second; a request can be issued across a change of the first.
        out.put(.interfaceKind(transaction.isCellular ? "cellular" : "other"))
        if transaction.isExpensive {
            out.put(.expensiveInterface(true))
        }
        if transaction.isConstrained {
            out.put(.constrainedInterface(true))
        }
        // Which POP served the request. `remoteAddress` is the server's and is
        // safe; `localAddress` is the device's own and is never emitted.
        if let remote = transaction.remoteAddress {
            out.put(.remoteAddress(remote))
        }
        // A corporate or VPN proxy explains latency and handshake oddities the
        // app has no other way of seeing, and the app did not configure it.
        if transaction.isProxyConnection {
            out.put(.proxyConnection(true))
        }
        if transaction.isMultipath {
            out.put(.multipath(true))
        }
        out.put(.dnsProtocol(name(of: transaction.domainResolutionProtocol)))
    }

    /// Named rather than numbered. `0x0304` is TLS 1.3 to somebody who already
    /// knows, and the reading is for somebody who does not.
    static func name(of version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv10: "TLS 1.0"
        case .TLSv11: "TLS 1.1"
        case .TLSv12: "TLS 1.2"
        case .TLSv13: "TLS 1.3"
        case .DTLSv10: "DTLS 1.0"
        case .DTLSv12: "DTLS 1.2"
        @unknown default: "unrecognised(0x\(String(version.rawValue, radix: 16)))"
        }
    }

    private static func name(
        of resolution: URLSessionTaskMetrics.DomainResolutionProtocol
    ) -> String {
        switch resolution {
        case .unknown: "unknown"
        case .udp: "udp"
        case .tcp: "tcp"
        case .tls: "tls"
        case .https: "https"
        @unknown default: "unrecognised(\(resolution.rawValue))"
        }
    }
}
#endif
