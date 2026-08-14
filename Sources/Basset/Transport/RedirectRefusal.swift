import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession replays the bearer token onto whatever host a 3xx names; neither endpoint redirects.
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
