import BassetECS
import Foundation
import ObjectiveC

/// What CallKit asked the app to do, and whether the call ever got audio.
///
/// `provider(_:didActivate:)` hands the app an `AVAudioSession` that CallKit
/// activated, not the app. "No audio after answering" is therefore a call symptom
/// with an audio mechanism, and the two connect only if something recorded that
/// the activation happened. A provider that reset is the other half of the same
/// silence.
///
/// **Wrapped, never defined.** `Swizzle.afterOrDefine` permits defining a callback
/// that returns nothing and carries no completion handler.
/// `provider:performAnswerCallAction:` satisfies both and is still unsafe to
/// define: the `CXAction` it carries must be fulfilled or failed, and CallKit ends
/// the call if nobody does. The obligation rides in the argument, not the
/// signature — so a callback may be defined only when it carries no obligation.
final class ProviderActions: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentWireID = .callProviderActions
    static let entity = Entity.WireID.callProvider

    static let providerClassName = "CXProvider"
    static let setDelegate: Selector = .init("setDelegate:queue:")

    /// Every one of these is void and handler-free, and every one is wrapped
    /// rather than defined, because an action the app never fulfils is a call
    /// CallKit ends.
    static let watched: [(selector: String, action: String)] = [
        ("provider:performAnswerCallAction:", "answered"),
        ("provider:performEndCallAction:", "ended"),
        ("provider:performSetHeldCallAction:", "held"),
        ("provider:performSetMutedCallAction:", "muted"),
        ("provider:didActivateAudioSession:", "audioActivated"),
        ("provider:didDeactivateAudioSession:", "audioDeactivated"),
    ]

    private let lock: NSLock = .init()
    private var counts: [String: UInt64] = [:]
    private var followed: [Int] = []

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        guard let provider = objc_getClass(providerClassName) as? AnyClass else {
            return
        }

        hooks.catchDelegateClass(at: setDelegate, on: provider)
    }

    func observe(_ context: Context) {
        guard let provider = objc_getClass(Self.providerClassName) as? AnyClass else {
            context.emit { out in
                out.put(.callAction("none"))
                out.put(.mechanismStatus("unavailable: this app does not use CallKit"))
            }
            return
        }

        let classes = context.registries.delegates(ObjectIdentifier(provider))
        let token = classes.attachAndFollow { [weak self] delegateClass in
            self?.watch(delegateClass, context)
        }
        lock.withLock { followed.append(token) }
    }

    func stopObserving() {
        lock.withLock {
            counts.removeAll()
            followed.removeAll()
        }
    }

    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        for entry in Self.watched {
            let selector = Selector((entry.selector))
            // Absent means the app does not handle it, which for an action is a
            // finding of its own — and defining it would make CallKit deliver an
            // action nobody fulfils.
            guard class_getInstanceMethod(delegateClass, selector) != nil
            else {
                continue
            }

            _ = context.swizzle.after(delegateClass, selector, takingTwoObjects: ()) {
                [weak self] _, _, _ in
                self?.performed(entry.action, of: delegateClass, into: context)
            }
        }

        let handled = Self.watched.filter {
            class_getInstanceMethod(delegateClass, Selector(($0.selector))) != nil
        }
        context.emit { out in
            out.put(.callAction("watching"))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.occurrenceCount(UInt64(handled.count)))
            if handled.isEmpty {
                out
                    .put(
                        .mechanismStatus(
                            "the provider delegate handles none of the watched actions"
                        )
                    )
            }
        }
    }

    private func performed(
        _ action: String,
        of delegateClass: AnyClass,
        into context: Context
    ) {
        let count = lock.withLock { () -> UInt64 in
            counts[action, default: 0] += 1
            return counts[action] ?? 1
        }
        context.emit { out in
            out.put(.callAction(action))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.occurrenceCount(count))
        }
    }
}
