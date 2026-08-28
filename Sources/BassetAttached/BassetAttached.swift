import Basset
import Foundation

/// Linking this module is what lets an app reach a control plane and a frame sink on
/// this machine. It is a separate product so a shipped build cannot link it by
/// accident, and every symbol in it is compiled away outside a debug build.
public enum BassetAttached {
    /// Loopback names only. A certificate presented by anything else is still checked
    /// the ordinary way, so this cannot be turned into blanket trust by a redirect.
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Accepts the certificate a `basset attached` on this machine presents, which is
    /// generated per machine and signed by nobody. Verifying it would otherwise mean
    /// installing it in the trust store — impossible on a device without a profile,
    /// and on a simulator it accumulates a root certificate per attach.
    public static func trustTheLoopbackControlPlane() {
        #if DEBUG
        LoopbackTrust.accept = { challenge in
            let space = challenge.protectionSpace
            guard
                space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                loopbackHosts.contains(space.host),
                let trust = space.serverTrust
            else {
                return nil
            }

            return URLCredential(trust: trust)
        }
        #endif
    }

    public static func stopTrustingTheLoopbackControlPlane() {
        #if DEBUG
        LoopbackTrust.accept = nil
        #endif
    }
}
