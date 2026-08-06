import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Sheets and modal SwiftUI screens, in the order they opened and closed.
///
/// "The sheet does not appear" and "the sheet closes itself" are ordinary
/// SwiftUI bug reports with no signal behind them, because the presentation is
/// driven by a binding the SDK cannot see. What it can see is UIKit doing the
/// presenting underneath, which answers the question that matters first: did the
/// presentation happen at all.
final class Presentation: StreamingInstrument {
    static let id: InstrumentWireID = .swiftUIPresentation
    static let entity = Entity.WireID.swiftUIPresentation

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.settled(receiver, transition: "presented", context)
        }

        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidDisappear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.settled(receiver, transition: "dismissed", context)
        }
        #endif
    }

    func stopObserving() {}

    #if canImport(UIKit)
    private func settled(_ receiver: AnyObject, transition: String, _ context: Context) {
        guard let kind = SwiftUIHost.kind(of: receiver),
              let controller = receiver as? UIViewController
        else {
            return
        }

        // Presented rather than pushed or installed as a root. A screen that
        // arrived by navigation is `swiftui.host.appear`'s to report, and
        // emitting it here as well would double every reading.
        if transition == "presented" {
            guard controller.presentingViewController != nil else {
                return
            }
        } else {
            guard controller.isBeingDismissed else {
                return
            }
        }

        let root = SwiftUIHost.rootView(of: receiver)
        context.emit { out in
            out.put(.detail(transition))
            out.put(.presentationKind(Self.style(of: controller)))
            out.put(.presentedRootViewType(root.name))
            out.put(.hostKind(kind.rawValue))
            if let title = SwiftUIHost.title(of: controller) {
                out.put(.hostNavigationTitle(title))
            }
        }
    }

    private static func style(of controller: UIViewController) -> String {
        switch controller.modalPresentationStyle {
        case .fullScreen: "fullScreen"
        case .pageSheet: "pageSheet"
        case .formSheet: "formSheet"
        case .currentContext: "currentContext"
        case .custom: "custom"
        case .overFullScreen: "overFullScreen"
        case .overCurrentContext: "overCurrentContext"
        case .popover: "popover"
        case .automatic: "automatic"
        case .none: "none"
        @unknown default: "unknown"
        }
    }
    #endif
}
