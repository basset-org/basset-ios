import BassetECS
import Foundation

#if canImport(UIKit)
import UIKit
#endif

final class ViewControllerAppear: Streamable, PlainInstrument {
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

final class ViewLayoutPass: Streamable, PlainInstrument {
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

/// Assigns each live touch a stable id across its began/moved/ended readings — the correlation
/// key a paired reading (a hierarchy snapshot taken for it) is found again by. UIKit-free, so
/// it's testable without a `UITouch`, which has no reachable initializer.
struct TouchIdentifiers {
    private var assigned: [ObjectIdentifier: UInt32] = [:]
    private var next: UInt32 = 0

    mutating func begin(_ touch: ObjectIdentifier) -> UInt32 {
        next &+= 1
        assigned[touch] = next
        return next
    }

    /// `nil` only if `begin` was never called for this touch — teardown mid-gesture.
    mutating func end(_ touch: ObjectIdentifier) -> UInt32? {
        assigned.removeValue(forKey: touch)
    }
}

/// Touch begin/end/cancel are timestamped; `moved` events are counted once a second instead.
final class WindowTouches: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let hierarchy: Bool
    }

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

    /// Off by default — the walk this triggers is the cost `instrument-domains.md` refuses to
    /// pay on every touch; asking for it is opting into paying it on `.began` only.
    static let defaultConfig: Config = .init(hierarchy: false)

    private let hierarchy: Bool
    private let moves: Mutex<Moves> = .init(Moves())
    private let touchIds: Mutex<TouchIdentifiers> = .init(TouchIdentifiers())

    init(config: Config) {
        hierarchy = config.hierarchy
    }

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
        touchIds.withLock { $0 = TouchIdentifiers() }
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
        let phase = touch.phase
        let location = touch.location(in: nil)
        let key = ObjectIdentifier(touch)

        let id: UInt32? =
            if phase == .began {
                touchIds.withLock { $0.begin(key) }
            } else {
                touchIds.withLock { $0.end(key) }
            }

        context.emit { out in
            out.put(.touchPhase(Self.name(of: phase)))
            out.put(.activeTouchCount(UInt32(clamping: active)))
            out.put(.originXPoints(Double(location.x)))
            out.put(.originYPoints(Double(location.y)))
            if let id {
                out.put(.touchId(id))
            }

            guard hierarchy, phase == .began, let id, let window = touch.window else {
                return
            }

            out.also(.viewHierarchy) { hier in
                ViewHierarchy.writeMatches(at: location, in: window, touchId: id, into: &hier)
            }
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

/// Which views a point falls inside, topmost first — the read `hitTest:withEvent:` would answer,
/// without swizzling it: one walk on request, never one per touch continuously.
final class ViewHierarchy: Snapshotable, Configurable {
    struct Config: Codable, Sendable {
        let x: Double
        let y: Double
    }

    static let id: InstrumentID = .viewHierarchy
    static let entity = Entity.ID.viewHierarchy

    static let defaultConfig: Config = .init(x: 0, y: 0)

    /// Past this, a hierarchy's finding is in the count, not the list.
    static let ceiling = 64

    #if canImport(UIKit)
    private let point: CGPoint
    #endif

    init(config: Config) {
        #if canImport(UIKit)
        point = CGPoint(x: config.x, y: config.y)
        #endif
    }

    #if canImport(UIKit)
    /// The on-demand config path: resolves the key window itself, since no touch supplies one.
    static func write(at point: CGPoint, touchId: UInt32?, into out: inout Readings) {
        guard let window = keyWindow() else {
            out.put(.mechanismStatus("unavailable: no key window"))
            if let touchId {
                out.put(.touchId(touchId))
            }
            return
        }

        writeMatches(at: point, in: window, touchId: touchId, into: &out)
    }

    /// The walk itself, against a caller-supplied root. `WindowTouches` calls this directly
    /// with the touch's own window — the only way to answer "what got hit" without a round
    /// trip the hierarchy might not survive. Also reachable directly against a constructed
    /// view tree, since a test bundle process has no key window of its own.
    static func writeMatches(
        at point: CGPoint,
        in root: UIView,
        touchId: UInt32?,
        into out: inout Readings
    ) {
        let hits = matches(at: point, in: root)
        guard let first = hits.first else {
            out.put(.mechanismStatus("unavailable: nothing at that point"))
            if let touchId {
                out.put(.touchId(touchId))
            }
            return
        }

        put(first, in: root, touchId: touchId, into: &out)
        for view in hits.dropFirst().prefix(ceiling - 1) {
            out.also(Self.entity) { sibling in
                put(view, in: root, touchId: touchId, into: &sibling)
            }
        }

        guard hits.count > ceiling else {
            return
        }

        out.also(Self.entity) { sibling in
            sibling.put(.mechanismStatus("truncated: \(hits.count - ceiling) more"))
        }
    }

    /// `view.frame` is superview-relative — three levels deep that is not the window
    /// coordinate space this instrument promises, so `bounds` is converted to `root` instead.
    private static func put(
        _ view: UIView,
        in root: UIView,
        touchId: UInt32?,
        into out: inout Readings
    ) {
        let inRoot = view.convert(view.bounds, to: root)
        out.put(.runtimeClassName(String(describing: type(of: view))))
        out.put(.originXPoints(Double(inRoot.origin.x)))
        out.put(.originYPoints(Double(inRoot.origin.y)))
        out.put(.frameWidthPoints(Double(inRoot.width)))
        out.put(.frameHeightPoints(Double(inRoot.height)))
        if let touchId {
            out.put(.touchId(touchId))
        }
    }

    /// Depth first, front to back: a subview drawn later sits on top of an earlier one, so its
    /// own matches — and the matches of everything drawn on top of it — lead the result.
    private static func matches(at point: CGPoint, in view: UIView) -> [UIView] {
        guard !view.isHidden, view.alpha > 0.01, view.bounds.contains(point) else {
            return []
        }

        var found: [UIView] = [view]
        for subview in view.subviews.reversed() {
            found = matches(at: subview.convert(point, from: view), in: subview) + found
        }
        return found
    }

    private static func keyWindow() -> UIWindow? {
        HostApplication.shared?
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
    #endif

    func reading(_ out: inout Readings) {
        #if canImport(UIKit)
        Self.write(at: point, touchId: nil, into: &out)
        #endif
    }
}

/// Which control fired and where the action went — `sendAction:to:forEvent:` is UIKit's own
/// funnel for every button, switch and control event, so one hook covers all of them.
final class ControlAction: Streamable, PlainInstrument {
    static let id: InstrumentID = .controlAction
    static let entity = Entity.ID.controlAction

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIControl.self,
            #selector(UIControl.sendAction(_:to:for:)),
            takingSelectorAndTwoObjects: ()
        ) { [weak self] (_, action: Selector, target: AnyObject?, _: AnyObject?) in
            self?.fired(action, target, context)
        }
        #endif
    }

    func stopObserving() {}

    #if canImport(UIKit)
    private func fired(_ action: Selector, _ target: AnyObject?, _ context: Context) {
        context.emit { out in
            out.put(.methodName(NSStringFromSelector(action)))
            guard let target else {
                return
            }

            out.put(.methodClass(String(describing: type(of: target))))
        }
    }
    #endif
}

/// Which gesture recognizer transitioned and to what. `setState:` is not in the public header —
/// this hooks it by selector name, and the install fails soft if it's ever gone.
final class GestureState: Streamable, PlainInstrument {
    static let id: InstrumentID = .gestureState
    static let entity = Entity.ID.gestureRecognizer

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIGestureRecognizer.self,
            NSSelectorFromString("setState:"),
            takingInteger: ()
        ) { [weak self] (receiver, state: Int) in
            self?.changed(receiver, state, context)
        }
        #endif
    }

    func stopObserving() {}

    #if canImport(UIKit)
    private func changed(_ receiver: AnyObject, _ state: Int, _ context: Context) {
        guard let recognized = UIGestureRecognizer.State(rawValue: state) else {
            return
        }

        context.emit { out in
            out.put(.runtimeClassName(String(describing: type(of: receiver))))
            out.put(.gestureRecognizerState(Self.name(of: recognized)))
        }
    }

    /// `.recognized` shares `.ended`'s raw value — a discrete recognizer's own name for it.
    private static func name(of state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "unknown"
        }
    }
    #endif
}
