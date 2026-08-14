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

            // Nanoseconds as the clock gave them; converting on-device would lose precision.
            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.passCount(passes))
            out.put(.totalNanoseconds(context.tally.take(Self.totalNanoseconds)))
            out.put(.peakNanoseconds(context.tally.take(Self.peakNanoseconds)))
        }
        #endif
    }

    func stopObserving() {}
}

/// Touch begin/end/cancel are timestamped; `moved` events are counted once a second instead.
final class WindowTouches: StreamingInstrument {
    private struct Moves {
        var count: UInt32 = 0
        var distancePoints: Double = 0
        var mostAtOnce: UInt32 = 0

        var isEmpty: Bool {
            count == 0
        }
    }

    static let id: InstrumentID = .windowTouches
    static let entity = Entity.ID.touches

    private let moves: Mutex<Moves> = .init(Moves())

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIWindow.self,
            #selector(UIWindow.sendEvent(_:))
        ) { [weak self] (_, argument: AnyObject?) in
            self?.received(argument, context)
        }

        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self, let taken = self.takeMoves() else {
                return
            }

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.touchesMovedCount(taken.count))
            let distance = min(max(taken.distancePoints.rounded(), 0), Double(UInt32.max))
            out.put(.dragDistancePoints(UInt32(distance)))
            out.put(.maximumSimultaneousTouchCount(taken.mostAtOnce))
        }
        #endif
    }

    func stopObserving() {
        moves.withLock { $0 = Moves() }
    }

    #if canImport(UIKit)
    private func received(_ argument: AnyObject?, _ context: Context) {
        guard let event = argument as? UIEvent, event.type == .touches,
              let touches = event.allTouches
        else {
            return
        }

        var moved: UInt32 = 0
        var travelled: Double = 0
        var stillDown = 0

        // Only phases still down are counted: a releasing touch stays in the event's set too.
        for touch in touches {
            switch touch.phase {
            case .began,
                 .moved,
                 .stationary:
                stillDown += 1
            default:
                break
            }
        }

        for touch in touches {
            switch touch.phase {
            case .began,
                 .cancelled,
                 .ended:
                report(touch, among: stillDown, context)
            case .moved:
                moved += 1
                travelled += Self.travelled(by: touch)
            default:
                continue
            }
        }

        guard moved > 0 else {
            return
        }

        let atOnce = UInt32(clamping: stillDown)
        moves.withLock { moves in
            moves.count += moved
            // A NaN coordinate would poison the sum and trap the conversion at flush.
            if travelled.isFinite {
                moves.distancePoints += travelled
            }
            moves.mostAtOnce = max(moves.mostAtOnce, atOnce)
        }
    }

    /// `UITouch` carries its last location, so no per-touch table is needed.
    private static func travelled(by touch: UITouch) -> Double {
        let now = touch.location(in: nil)
        let before = touch.previousLocation(in: nil)
        return Double(hypot(now.x - before.x, now.y - before.y))
    }

    private static func name(of phase: UITouch.Phase) -> String {
        switch phase {
        case .began: "began"
        case .ended: "ended"
        case .cancelled: "cancelled"
        default: "unknown"
        }
    }

    private func report(_ touch: UITouch, among active: Int, _ context: Context) {
        let phase = Self.name(of: touch.phase)
        context.emit { out in
            out.put(.touchPhase(phase))
            out.put(.activeTouchCount(UInt32(clamping: active)))
        }
    }
    #endif

    private func takeMoves() -> Moves? {
        moves.withLock { moves -> Moves? in
            defer { moves = Moves() }
            return moves.isEmpty ? nil : moves
        }
    }
}
