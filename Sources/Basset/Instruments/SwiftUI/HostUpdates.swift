import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How hard SwiftUI is working, measured where SwiftUI meets UIKit.
///
/// A re-render loop is the SwiftUI failure with the largest gap between how
/// often developers hit it and how little tooling sees it. It is invisible to
/// `uikit.view.layoutPass`, which counts every view in the process and drowns
/// one host in the app's ordinary layout traffic.
///
/// The hook is installed on the hosting view's class alone — obtained from a
/// live instance, never looked up by name — so only SwiftUI content pays for it.
///
/// **Nothing but counting happens in the hook, and that is a correctness rule
/// rather than a budget.** Capture work on a swizzled layout call stack induces
/// AttributeGraph cycles in the app. Reading a view tree or reflecting a display
/// list from here reproduces that.
final class HostUpdates: StreamingInstrument, @unchecked Sendable {
    static let id: InstrumentWireID = .swiftUIHostUpdates
    static let entity = Entity.WireID.swiftUIHost

    private static let passes: TallySlot = .first
    private static let totalNanoseconds: TallySlot = .second
    private static let peakNanoseconds: TallySlot = .third

    private let lock: NSLock = .init()
    private var hookedClasses: Set<ObjectIdentifier> = []
    private var lastHookedName: String?

    #if canImport(UIKit)
    private let hosts: WeakRegistry<UIViewController> = .init()
    #endif

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.appeared(receiver, context)
        }

        context.flush(every: .seconds(1)) { [weak self] out, window in
            let passes = context.tally.take(Self.passes)
            guard passes > 0 else {
                return
            }

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.passCount(passes))
            out.put(.totalNanoseconds(context.tally.take(Self.totalNanoseconds)))
            out.put(.peakNanoseconds(context.tally.take(Self.peakNanoseconds)))
            guard let self else {
                return
            }

            out.put(.hostCount(UInt32(hosts.count)))
            lock.lock()
            let name = lastHookedName
            lock.unlock()
            if let name {
                out.put(.hostViewClass(name))
            }
        }
        #endif
    }

    func stopObserving() {
        lock.lock()
        hookedClasses.removeAll()
        lastHookedName = nil
        lock.unlock()
    }

    #if canImport(UIKit)
    private func appeared(_ receiver: AnyObject, _ context: Context) {
        guard SwiftUIHost.kind(of: receiver) != nil,
              let controller = receiver as? UIViewController,
              let hostingView = SwiftUIHost.hostingViewClass(of: controller)
        else {
            return
        }

        hosts.add(controller)

        let key = ObjectIdentifier(hostingView)
        lock.lock()
        let alreadyHooked = hookedClasses.contains(key)
        if !alreadyHooked {
            hookedClasses.insert(key)
            lastHookedName = NSStringFromClass(hostingView)
        }
        lock.unlock()
        guard !alreadyHooked else {
            return
        }

        // Off this call stack on purpose. Installing a hook from inside a
        // running hook re-enters the swizzle table's lock, and the delay
        // costs one run-loop turn of a counter that aggregates over a second.
        DispatchQueue.main.async { [weak self] in
            self?.hookLayout(of: hostingView, context)
        }
    }

    private func hookLayout(of hostingView: AnyClass, _ context: Context) {
        let hot = context.hotPath
        _ = context.swizzle.timing(hostingView, #selector(UIView.layoutSubviews)) {
            _, elapsed in
            guard hot.isActive else {
                return
            }

            hot.add(Self.passes)
            hot.add(Self.totalNanoseconds, elapsed)
            hot.raise(Self.peakNanoseconds, to: elapsed)
        }
    }
    #endif
}
