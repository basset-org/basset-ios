import Foundation

#if DEBUG
/// Where readings go while a developer's machine is attached: a socket that machine
/// dialled, rather than an ingest endpoint reached over a network.
public protocol AttachedChannel: AnyObject, Sendable {
    func send(_ frame: Data)
}

/// The whole of what `BassetAttached` needs from this library. Compiled out of a
/// release build entirely: applying desired state from inside the process would
/// otherwise let anything linked into a shipped app activate instruments.
public enum AttachedBridge {
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var attached: AttachedChannel?
    /// Held so the order of `Basset.start` and `BassetAttached.listen` does not
    /// matter: state arriving before there is a loop to apply it to is applied once
    /// there is one.
    private nonisolated(unsafe) static var pending: Data?

    static var channel: AttachedChannel? {
        lock.withLock { attached }
    }

    public static func open(_ channel: AttachedChannel) {
        lock.withLock { attached = channel }
        Basset.forgetAttachedTransports()
    }

    /// Only the channel that is current may close it: an old connection cancelling
    /// after a new one has opened would otherwise switch the live one off. Passing
    /// nothing closes whatever is open and is for tearing the process down, never
    /// for a connection reporting its own end.
    public static func close(_ channel: AttachedChannel? = nil) {
        let closed = lock.withLock { () -> Bool in
            guard let channel else {
                attached = nil
                return true
            }
            guard attached === channel else {
                return false
            }

            attached = nil
            return true
        }
        guard closed else {
            return
        }

        Basset.forgetAttachedTransports()
    }

    public static func apply(_ desiredState: Data) throws {
        let state = try JSONDecoder().decode(DesiredState.self, from: desiredState)
        guard Basset.converge(to: state) else {
            lock.withLock { pending = desiredState }
            return
        }
    }

    /// The same document the control plane answers a poll with, pushed down the
    /// socket instead. Decoded by the same decoder, so the two cannot disagree.
    static func whileNothingIsAttached(_ converge: () -> Void) {
        lock.withLock {
            guard attached == nil else {
                return
            }

            converge()
        }
    }

    static func applyWhatArrivedBeforeTheLoop() {
        guard let waiting = lock.withLock({ pending }) else {
            return
        }

        lock.withLock { pending = nil }
        try? apply(waiting)
    }
}

final class AttachedTransport: Transport, @unchecked Sendable {
    private let channel: AttachedChannel

    init(_ channel: AttachedChannel) {
        self.channel = channel
    }

    func send(_ frame: Data) {
        channel.send(frame)
    }

    func close() {}
}
#endif
