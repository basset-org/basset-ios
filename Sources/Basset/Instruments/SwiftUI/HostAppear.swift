import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Which SwiftUI screen the user reached, named as the developer named it.
///
/// The type name alone is not enough. `AnyView` erases it, and dropping the
/// reading when that happens is the wrong end: an absent screen and a screen that
/// never appeared read the same in a capture.
///
/// So both names go out — the unwrapped type and the navigation title — and the
/// reading is marked when the type erased itself. Either one can be the useless
/// one.
final class HostAppear: StreamingInstrument {
    static let id: InstrumentWireID = .swiftUIHostAppear
    static let entity = Entity.WireID.swiftUIHost

    /// A screen that loaded and never appeared leaves an entry behind. The cap
    /// bounds that at a size no real app reaches, so a leak cannot grow with
    /// uptime.
    private static let pendingCeiling = 64

    private let lock: NSLock = .init()
    private var loadedAt: [ObjectIdentifier: UInt64] = [:]
    private var identifiers: [ObjectIdentifier: UInt32] = [:]

    #if canImport(UIKit)
    private let hosts: WeakRegistry<UIViewController> = .init()
    #endif

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        hosts.attachAndFollow { [weak self] controller, instance in
            guard let self else {
                return
            }

            lock.lock()
            identifiers[ObjectIdentifier(controller)] = instance
            lock.unlock()
        }

        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidLoad)
        ) { [weak self] receiver in
            self?.loaded(receiver, context)
        }

        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.appeared(receiver, context)
        }
        #endif
    }

    func stopObserving() {
        lock.lock()
        loadedAt.removeAll()
        identifiers.removeAll()
        lock.unlock()
    }

    #if canImport(UIKit)
    private func loaded(_ receiver: AnyObject, _ context: Context) {
        guard SwiftUIHost.kind(of: receiver) != nil else {
            return
        }

        lock.lock()
        if loadedAt.count >= Self.pendingCeiling {
            loadedAt.removeAll()
        }
        loadedAt[ObjectIdentifier(receiver)] = context.clock.now().nanoseconds
        lock.unlock()
    }

    private func appeared(_ receiver: AnyObject, _ context: Context) {
        guard let kind = SwiftUIHost.kind(of: receiver),
              let controller = receiver as? UIViewController
        else {
            return
        }

        hosts.add(controller)

        let key = ObjectIdentifier(receiver)
        lock.lock()
        let loaded = loadedAt.removeValue(forKey: key)
        let instance = identifiers[key]
        lock.unlock()

        let root = SwiftUIHost.rootView(of: receiver)

        context.emit { out in
            out.put(.hostKind(kind.rawValue))
            out.put(.hostRootViewType(root.name))
            out.put(.hostRootViewOpaque(root.isOpaque))
            out.put(.viewControllerClass(String(describing: type(of: receiver))))
            if let title = SwiftUIHost.title(of: controller) {
                out.put(.hostNavigationTitle(title))
            }
            if let loaded {
                out.put(.hostAppearNanoseconds(context.clock.now().nanoseconds - loaded))
            }
            if let instance {
                out.put(.instanceId(instance))
            }
            if let hostingView = SwiftUIHost.hostingViewClass(of: controller) {
                out.put(.hostViewClass(NSStringFromClass(hostingView)))
            }
            out.put(.hostCount(UInt32(hosts.count)))
        }
    }
    #endif
}
