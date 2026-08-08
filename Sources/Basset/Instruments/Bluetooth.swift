import BassetECS
import Foundation
import ObjectiveC

/// Why an app's Bluetooth feature does nothing, which the app usually cannot
/// tell from a peripheral simply not being there.
///
/// `CBCentralManager` refuses to scan unless its state is `poweredOn`, and says
/// so exactly once through a delegate callback the app may or may not act on.
/// Powered off, unauthorized and unsupported all look the same from outside — no
/// peripherals, ever, no error — and only the state tells them apart.
///
/// **basset never constructs a `CBCentralManager`.** Creating one raises the
/// `NSBluetoothAlwaysUsageDescription` prompt, which is a visible change to the
/// app. Everything here rides managers the app already made: the delegate class
/// is caught at `setDelegate:`, and the state is read off the central the
/// framework hands to the callback.
///
/// **Nothing about a peripheral is read.** A 16-bit assigned service UUID *is* a
/// device category — glucose monitor, hearing aid, CPAP — so a scan result is
/// health data. `CBPeripheral.identifier` is stable per accessory and `name` is
/// routinely a person's own words. This stays on the central's own state, where
/// none of that exists.
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

        hooks.catchDelegateClass(at: setDelegate, on: manager)
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
