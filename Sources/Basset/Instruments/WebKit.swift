import BassetECS
import Foundation
import ObjectiveC

/// The white blank: a `WKWebView` whose content process died.
///
/// WebKit runs page content in a separate process. When that process is killed —
/// usually for memory, on a page the app does not control — the web view does not
/// error, does not reload and does not tell the user. It goes **white**, and
/// stays white, and the app is generally unaware there was ever content in it.
///
/// WebKit only delivers `webViewWebContentProcessDidTerminate:` to a delegate
/// that responds to it, and most apps never wrote one — they do not know the
/// callback exists. So this **defines** the method on the app's delegate class
/// rather than wrapping an existing one, which makes WebKit start delivering a
/// callback the app was never receiving.
///
/// Safe only because of what this callback is: it returns nothing and carries no
/// completion handler, so defining it adds an observation and no behaviour.
/// `Swizzle.afterOrDefine` holds the rule, and the two shapes it excludes are
/// both in this framework — `decidePolicyFor…` and
/// `didReceiveAuthenticationChallenge` take completion handlers, and calling one
/// twice terminates the app. Neither is touched here.
final class ContentProcessTermination: StreamingInstrument, LoadTimeInstall {
    private struct State {
        var terminations: UInt64 = 0
        var followed: [Int] = []
    }

    static let id: InstrumentID = .webContentTermination
    static let entity = Entity.ID.webView

    static let webViewClassName = "WKWebView"
    static let setNavigationDelegate: Selector = .init("setNavigationDelegate:")
    static let didTerminate: Selector = .init("webViewWebContentProcessDidTerminate:")

    private let guarded: Mutex<State> = .init(State())

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        guard let webView = objc_getClass(webViewClassName) as? AnyClass else {
            return
        }

        hooks.catchDelegateClass(at: setNavigationDelegate, on: webView)
    }

    private static func url(of webView: AnyObject?) -> String? {
        let selector = Selector(("URL"))
        guard let webView,
              webView.responds(to: selector),
              let url = webView.value(forKey: "URL") as? URL
        else {
            return nil
        }

        let redacted = Redaction.url(url)
        return redacted.isEmpty ? nil : redacted
    }

    func observe(_ context: Context) {
        guard let webView = objc_getClass(Self.webViewClassName) as? AnyClass else {
            context.emit { out in
                out.put(.contentProcessTerminations(0))
                out.put(.mechanismStatus("unavailable: this app does not use a web view"))
            }
            return
        }

        let classes = context.registries.delegates(ObjectIdentifier(webView))
        let token = classes.attachAndFollow { [weak self] delegateClass in
            self?.watch(delegateClass, context)
        }
        guarded.withLock { $0.followed.append(token) }
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
    }

    /// Whether the app was already listening is itself worth reporting: an app
    /// that implements this callback usually reloads on it, and one that does not
    /// leaves the user looking at a white rectangle.
    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        let appWasListening = class_getInstanceMethod(delegateClass, Self.didTerminate) !=
            nil
        let outcome = context.swizzle.afterOrDefine(delegateClass, Self.didTerminate) {
            [weak self] _, webView in
            self?.terminated(webView, of: delegateClass, into: context)
        }

        guard outcome == .installed || outcome == .joinedExisting || outcome ==
            .implemented
        else {
            context.emit { out in
                out.put(.contentProcessTerminations(0))
                out.put(.delegateClass(NSStringFromClass(delegateClass)))
                out.put(.mechanismStatus("unavailable: \(outcome)"))
            }
            return
        }

        context.emit { out in
            out.put(.contentProcessTerminations(0))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.callbackImplemented(appWasListening))
            if !appWasListening {
                out.put(
                    .mechanismStatus(
                        "the app does not handle content-process termination"
                    )
                )
            }
        }
    }

    private func terminated(
        _ webView: AnyObject?,
        of delegateClass: AnyClass,
        into context: Context
    ) {
        let count = guarded.withLock { state -> UInt64 in
            state.terminations += 1
            return state.terminations
        }

        context.emit { out in
            out.put(.contentProcessTerminations(count))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            // Redacted the same way every other URL in the catalog is: scheme
            // and host, id-shaped path segments replaced, query dropped whole.
            if let url = Self.url(of: webView) {
                out.put(.requestURL(url))
            }
        }
    }
}
