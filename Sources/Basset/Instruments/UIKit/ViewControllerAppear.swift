import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class ViewControllerAppear: StreamingInstrument {
    static let id: InstrumentWireID = .viewControllerAppear
    static let entity = Entity.WireID.screen

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            self?.appeared(receiver, context)
        }
        #endif
    }

    func stopObserving() {}

    private func appeared(_ receiver: AnyObject, _ context: Context) {
        context.emit { out in
            out.put(.viewControllerClass(String(describing: type(of: receiver))))
        }
    }
}
