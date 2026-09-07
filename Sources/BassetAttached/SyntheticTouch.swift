import Basset
import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
/// One finger, delivered the way UIKit's own event fetcher delivers one: a private `UITouch`
/// carrying an IOHID digitizer event, added to the application's touches event and sent
/// with `sendEvent:`. It goes through hit-testing and every gesture recognizer, which is
/// the whole point — a control that a finger cannot work is one this cannot work either.
/// Every private selector is checked before use and reported by name when missing.
final class SyntheticTouch {
    enum Unsupported: Error, CustomStringConvertible {
        case selector(String)
        case symbol(String)
        case noKeyWindow

        var description: String {
            switch self {
            case .selector(let name): "unsupportedSelector:\(name)"
            case .symbol(let name): "unsupportedSymbol:\(name)"
            case .noKeyWindow: "noKeyWindow"
            }
        }
    }

    // MARK: - Private selectors

    private static let setWindow: Selector = .init("setWindow:")
    private static let setTapCount: Selector = .init("setTapCount:")
    private static let setLocation: Selector = .init("_setLocationInWindow:resetPrevious:")
    private static let setView: Selector = .init("setView:")
    private static let setPhase: Selector = .init("setPhase:")
    private static let setIsFirstTouchForView: Selector = .init("_setIsFirstTouchForView:")
    private static let setTimestamp: Selector = .init("setTimestamp:")
    private static let setPathIndex: Selector = .init("_setPathIndex:")
    private static let setPathIdentity: Selector = .init("_setPathIdentity:")
    private static let setSenderID: Selector = .init("_setSenderID:")
    private static let setHIDEvent: Selector = .init("_setHidEvent:")
    private static let setResponder: Selector = .init("_setResponder:")
    private static let touchesEvent: Selector = .init("_touchesEvent")
    private static let clearTouches: Selector = .init("_clearTouches")
    private static let addTouch: Selector = .init("_addTouch:forDelayedDelivery:")
    private static let setEventHIDEvent: Selector = .init("_setHIDEvent:")
    private static let hitTestWithContext: Selector = .init("_hitTestWithContext:")
    private static let contextWithPoint: Selector = .init("contextWithPoint:radius:")

    let window: UIWindow
    private(set) var hitView: UIView?
    private(set) var location: CGPoint

    private let touch: UITouch
    private let hid: HIDEvents

    /// `tapCount` is what a tap recognizer reads to tell the second tap of a double tap from
    /// two single taps.
    init(at point: CGPoint, in window: UIWindow, tapCount: Int = 1) throws {
        self.window = window
        location = point
        hid = try HIDEvents()
        touch = UITouch()
        try Self.require(touch, Self.setWindow, Self.setTapCount, Self.setLocation, Self.setView,
                         Self.setPhase, Self.setTimestamp, Self.setHIDEvent)
        try Self.require(UIApplication.shared, Self.touchesEvent)

        SyntheticTouches.mark(touch)
        Self.send(touch, Self.setWindow, window)
        Self.send(touch, Self.setTapCount, max(1, tapCount))
        Self.send(touch, Self.setLocation, point, true)
        hitView = window.hitTest(point, with: nil)
        Self.send(touch, Self.setView, hitView)
        if let responder = Self.responder(at: point, from: hitView),
           touch.responds(to: Self.setResponder)
        {
            Self.send(touch, Self.setResponder, responder)
        }
        if touch.responds(to: Self.setIsFirstTouchForView) {
            Self.send(touch, Self.setIsFirstTouchForView, true)
        }
        if touch.responds(to: Self.setPathIndex) {
            Self.send(touch, Self.setPathIndex, 1)
        }
        if touch.responds(to: Self.setPathIdentity) {
            Self.send(touch, Self.setPathIdentity, 2)
        }
        if touch.responds(to: Self.setSenderID) {
            Self.send(touch, Self.setSenderID, 0x0acefade00000002 as UInt64)
        }
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private static func require(_ object: AnyObject, _ selectors: Selector...) throws {
        for selector in selectors where !object.responds(to: selector) {
            throw Unsupported.selector(NSStringFromSelector(selector))
        }
    }

    private static func implementation(_ object: AnyObject, _ selector: Selector) -> IMP? {
        guard object.responds(to: selector) else {
            return nil
        }

        return class_getMethodImplementation(object_getClass(object), selector)
    }

    private static func send(_ object: AnyObject, _ selector: Selector) -> AnyObject? {
        typealias Call = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        guard let imp = implementation(object, selector) else {
            return nil
        }

        return unsafeBitCast(imp, to: Call.self)(object, selector)?.takeUnretainedValue()
    }

    private static func send(_ object: AnyObject, _ selector: Selector, _ argument: AnyObject?) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument)
    }

    private static func send(_ object: AnyObject, _ selector: Selector, _ argument: Int) {
        typealias Call = @convention(c) (AnyObject, Selector, Int) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument)
    }

    private static func send(_ object: AnyObject, _ selector: Selector, _ argument: UInt64) {
        typealias Call = @convention(c) (AnyObject, Selector, UInt64) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument)
    }

    private static func send(_ object: AnyObject, _ selector: Selector, _ argument: Bool) {
        typealias Call = @convention(c) (AnyObject, Selector, Bool) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument)
    }

    private static func send(_ object: AnyObject, _ selector: Selector, _ argument: Double) {
        typealias Call = @convention(c) (AnyObject, Selector, Double) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument)
    }

    private static func send(
        _ object: AnyObject,
        _ selector: Selector,
        _ argument: UnsafeMutableRawPointer?
    ) {
        typealias Call = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument)
    }

    private static func send(
        _ object: AnyObject,
        _ selector: Selector,
        _ point: CGPoint,
        _ flag: Bool
    ) {
        typealias Call = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, point, flag)
    }

    private static func send(
        _ object: AnyObject,
        _ selector: Selector,
        _ argument: AnyObject?,
        _ flag: Bool
    ) {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
        guard let imp = implementation(object, selector) else {
            return
        }

        unsafeBitCast(imp, to: Call.self)(object, selector, argument, flag)
    }

    /// The responder UIKit resolves for a SwiftUI-hosted point — a hit-test context walked
    /// up from the hit view — where a plain `hitTest:` stops at the hosting view.
    private static func responder(at point: CGPoint, from hitView: UIView?) -> AnyObject? {
        guard let contextClass = NSClassFromString("_UIHitTestContext") as? NSObject.Type,
              contextClass.responds(to: contextWithPoint),
              UIView.instancesRespond(to: hitTestWithContext)
        else {
            return nil
        }

        typealias MakeContext = @convention(c) (AnyObject, Selector, CGPoint, CGFloat)
            -> Unmanaged<AnyObject>?
        guard let makeImplementation = class_getMethodImplementation(
            object_getClass(contextClass),
            contextWithPoint
        ) else {
            return nil
        }

        let make = unsafeBitCast(makeImplementation, to: MakeContext.self)
        guard let context = make(contextClass, contextWithPoint, point, 0)?.takeUnretainedValue()
        else {
            return nil
        }

        typealias HitTest = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        var current = hitView
        while let view = current {
            guard let imp = implementation(view, hitTestWithContext) else {
                return nil
            }

            let found = unsafeBitCast(imp, to: HitTest.self)(
                view,
                hitTestWithContext,
                context
            )?.takeUnretainedValue()
            if let found {
                return found
            }

            current = view.superview
        }
        return nil
    }

    /// One phase, one event: the touches event is cleared and rebuilt every time, because a
    /// reused event drops the ended phase on plain views.
    func send(_ phase: UITouch.Phase, at point: CGPoint) throws {
        if phase != .began {
            Self.send(touch, Self.setLocation, point, false)
        }
        location = point
        Self.send(touch, Self.setPhase, phase.rawValue)
        Self.send(touch, Self.setTimestamp, ProcessInfo.processInfo.systemUptime)

        let finger = hid.finger(at: point, phase: phase)
        Self.send(touch, Self.setHIDEvent, finger)

        defer { hid.release(finger) }

        guard let event = Self.send(UIApplication.shared, Self.touchesEvent) as? UIEvent else {
            throw Unsupported.selector(NSStringFromSelector(Self.touchesEvent))
        }

        try Self.require(event, Self.clearTouches, Self.addTouch)
        Self.send(event, Self.clearTouches)
        Self.send(event, Self.addTouch, touch, false)
        if event.responds(to: Self.setEventHIDEvent) {
            Self.send(event, Self.setEventHIDEvent, finger)
        }
        UIApplication.shared.sendEvent(event)
        if event.responds(to: Self.setEventHIDEvent) {
            Self.send(event, Self.setEventHIDEvent, nil as UnsafeMutableRawPointer?)
        }
    }

    /// A touch left in a non-terminal phase holds recognizers and scroll views for good.
    func cancel() {
        try? send(.cancelled, at: location)
    }
}

/// The IOKit digitizer functions UIKit expects a touch to carry, found by name at runtime.
final class HIDEvents {
    private typealias CreateDigitizer = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFinger = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Double, Double, Double, Double, Double,
        UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias SetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32) -> Void
    private typealias Append = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer)
        -> Void

    private static let transducerHand: UInt32 = 3
    private static let eventRange: UInt32 = 0x1
    private static let eventTouch: UInt32 = 0x2
    private static let eventPosition: UInt32 = 0x4
    private static let digitizerType: UInt32 = 11
    private static let fieldIsDisplayIntegrated: UInt32 = (digitizerType << 16) + 25

    private let createDigitizer: CreateDigitizer
    private let createFinger: CreateFinger
    private let setInteger: SetInteger
    private let append: Append

    init() throws {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw SyntheticTouch.Unsupported.symbol(name)
            }

            return unsafeBitCast(pointer, to: type)
        }
        createDigitizer = try symbol("IOHIDEventCreateDigitizerEvent", as: CreateDigitizer.self)
        createFinger = try symbol(
            "IOHIDEventCreateDigitizerFingerEventWithQuality",
            as: CreateFinger.self
        )
        setInteger = try symbol("IOHIDEventSetIntegerValue", as: SetInteger.self)
        append = try symbol("IOHIDEventAppendEvent", as: Append.self)
    }

    /// A hand event holding one finger, the shape UIKit's fetcher builds for a real touch.
    func finger(at point: CGPoint, phase: UITouch.Phase) -> UnsafeMutableRawPointer? {
        let now = mach_absolute_time()
        guard let hand = createDigitizer(
            nil, now, Self.transducerHand, 0, 0, Self.eventTouch, 0,
            0, 0, 0, 0, 0, 0, 1, 0
        ) else {
            return nil
        }

        setInteger(hand, Self.fieldIsDisplayIntegrated, 1)
        let mask = phase == .moved ? Self.eventPosition : (Self.eventRange | Self.eventTouch)
        let touching: UInt8 = phase == .ended || phase == .cancelled ? 0 : 1
        if let finger = createFinger(
            nil, now, 1, 2, mask,
            Double(point.x), Double(point.y), 0, 0, 0, 5, 5, 1, 1, 1,
            touching, touching, 0
        ) {
            setInteger(finger, Self.fieldIsDisplayIntegrated, 1)
            append(hand, finger)
            Unmanaged<AnyObject>.fromOpaque(finger).release()
        }
        return hand
    }

    func release(_ event: UnsafeMutableRawPointer?) {
        guard let event else {
            return
        }

        Unmanaged<AnyObject>.fromOpaque(event).release()
    }
}
#endif
