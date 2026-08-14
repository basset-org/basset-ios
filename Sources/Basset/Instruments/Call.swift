import BassetECS
import Foundation
import ObjectiveC

/// Wraps CallKit callbacks rather than defining them: the CXAction argument still needs fulfilling.
final class ProviderActions: StreamingInstrument, LoadTimeInstall {
    private struct State {
        var counts: [String: UInt64] = [:]
        var followed: [Int] = []
    }

    static let id: InstrumentID = .callProviderActions
    static let entity = Entity.ID.callProvider

    static let providerClassName = "CXProvider"
    static let setDelegate: Selector = .init("setDelegate:queue:")

    static let watched: [(selector: String, action: String)] = [
        ("provider:performAnswerCallAction:", "answered"),
        ("provider:performEndCallAction:", "ended"),
        ("provider:performSetHeldCallAction:", "held"),
        ("provider:performSetMutedCallAction:", "muted"),
        ("provider:didActivateAudioSession:", "audioActivated"),
        ("provider:didDeactivateAudioSession:", "audioDeactivated"),
    ]

    private let guarded: Mutex<State> = .init(State())

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        guard let provider = objc_getClass(providerClassName) as? AnyClass else {
            return
        }

        // `setDelegate:queue:` carries two arguments; the one-object catch refuses its shape.
        hooks.catchDelegateClass(at: setDelegate, on: provider, takingTwoObjects: ())
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
        guarded.withLock { $0.followed.append(token) }
    }

    func stopObserving() {
        guarded.withLock { $0 = State() }
    }

    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        for entry in Self.watched {
            let selector = Selector((entry.selector))
            // Absent is a finding of its own; defining it would deliver an action nobody fulfils.
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
        let count = guarded.withLock { state -> UInt64 in
            state.counts[action, default: 0] += 1
            return state.counts[action] ?? 1
        }
        context.emit { out in
            out.put(.callAction(action))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.occurrenceCount(count))
        }
    }
}
