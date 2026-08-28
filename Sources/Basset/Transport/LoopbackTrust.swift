import Foundation

#if DEBUG
/// Set only by BassetAttached, which a shipped build does not link. Nothing here is
/// compiled into a release build at all: a callback that can accept an unverified
/// certificate must not exist in an app on the store.
public enum LoopbackTrust {
    public nonisolated(unsafe) static var accept: (
        @Sendable (URLAuthenticationChallenge) -> URLCredential?
    )?
}
#endif
