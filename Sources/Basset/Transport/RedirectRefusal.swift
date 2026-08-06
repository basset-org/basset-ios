import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Every request basset makes carries a bearer token in its `authorization`
/// header, and URLSession replays that header onto whatever host a 3xx names.
/// Neither endpoint redirects, so a redirect is either a misconfiguration or
/// somebody asking for the token — and following one hands a request token,
/// which can write readings, to a host the device was never told to talk to.
///
/// Refused outright rather than restricted to same-host: neither endpoint has
/// that shape either, so a redirect means something is wrong, and the caller
/// sees the 3xx and can say so.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared: RedirectRefusal = .init()

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
