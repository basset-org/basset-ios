import BassetECS
import Foundation
import ObjectiveC

/// Rides an app-created `CBCentralManager`; constructing one would raise the usage prompt.
/// Never reads a peripheral — its identifier, name, and service UUID are personal/health data.
final class CentralState: StreamingInstrument, LoadTimeInstall {
    static let id: InstrumentID = .bluetoothCentralState
    static let entity = Entity.ID.bluetoothCentral

    static let managerClassName = "CBCentralManager"
    static let setDelegate: Selector = .init("setDelegate:")
    static let didUpdateState: Selector = .init("centralManagerDidUpdateState:")

    private let followed: Mutex<[Int]> = .init([])

    init() {}

    static func installAtLoad(_ hooks: HookTable) {
        guard let manager = objc_getClass(managerClassName) as? AnyClass else {
            return
        }

        hooks.trackDelegateClass(at: setDelegate, on: manager)
    }

    static func state(of central: AnyObject?) -> String {
        let selector = Selector(("state"))
        guard let central,
              central.responds(to: selector),
              let raw = (central.value(forKey: "state") as? NSNumber)?.intValue
        else {
            return "unknown"
        }

        return name(ofState: raw)
    }

    static func name(ofState raw: Int) -> String {
        switch raw {
        case 0: "unknown"
        case 1: "resetting"
        case 2: "unsupported"
        case 3: "unauthorized"
        case 4: "poweredOff"
        case 5: "poweredOn"
        default: "unrecognised(\(raw))"
        }
    }

    func observe(_ context: Context) {
        guard let manager = objc_getClass(Self.managerClassName) as? AnyClass else {
            context.emit { out in
                out.put(.bluetoothState("unknown"))
                out.put(.mechanismStatus("unavailable: CoreBluetooth is not loaded"))
            }
            return
        }

        let classes = context.registries.delegates(ObjectIdentifier(manager))
        let token = classes.attachAndFollow { [weak self] delegateClass in
            self?.watch(delegateClass, context)
        }
        followed.withLock { $0.append(token) }
    }

    func stopObserving() {
        followed.withLock { $0.removeAll() }
    }

    private func watch(_ delegateClass: AnyClass, _ context: Context) {
        guard class_getInstanceMethod(delegateClass, Self.didUpdateState) != nil else {
            context.emit { out in
                out.put(.bluetoothState("unknown"))
                out.put(.delegateClass(NSStringFromClass(delegateClass)))
                out.put(.callbackImplemented(false))
                out.put(
                    .mechanismStatus(
                        "the delegate does not implement centralManagerDidUpdateState:"
                    )
                )
            }
            return
        }

        _ = context.swizzle.after(delegateClass, Self.didUpdateState) { [weak self] (
            _,
            central: AnyObject?
        ) in
            self?.report(central, of: delegateClass, into: context)
        }
    }

    private func report(
        _ central: AnyObject?,
        of delegateClass: AnyClass,
        into context: Context
    ) {
        context.emit { out in
            out.put(.bluetoothState(Self.state(of: central)))
            out.put(.delegateClass(NSStringFromClass(delegateClass)))
            out.put(.callbackImplemented(true))
        }
    }
}
