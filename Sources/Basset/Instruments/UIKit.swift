import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

final class ViewControllerAppear: StreamingInstrument {
    static let id: InstrumentID = .viewControllerAppear
    static let entity = Entity.ID.screen

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

final class ViewLayoutPass: StreamingInstrument {
    static let id: InstrumentID = .viewLayoutPass
    static let entity = Entity.ID.viewLayout

    private static let passes: TallySlot = .first
    private static let totalNanoseconds: TallySlot = .second
    private static let peakNanoseconds: TallySlot = .third

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        let hot = context.hotPath
        _ = context.swizzle
            .timing(UIView.self, #selector(UIView.layoutSubviews)) { _, elapsed in
                guard hot.isActive else {
                    return
                }

                hot.add(Self.passes)
                hot.add(Self.totalNanoseconds, elapsed)
                hot.raise(Self.peakNanoseconds, to: elapsed)
            }

        context.flush(every: .seconds(1)) { out, window in
            let passes = context.tally.take(Self.passes)
            guard passes > 0 else {
                return
            }

            // Nanoseconds as the clock gave them. Dividing to milliseconds
            // here put a presentation choice on the device, lost precision
            // on a ~119ns no-op pass, and left the unit unrecoverable by
            // anything reading the capture.
            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.passCount(passes))
            out.put(.totalNanoseconds(context.tally.take(Self.totalNanoseconds)))
            out.put(.peakNanoseconds(context.tally.take(Self.peakNanoseconds)))
        }
        #endif
    }

    func stopObserving() {}
}
