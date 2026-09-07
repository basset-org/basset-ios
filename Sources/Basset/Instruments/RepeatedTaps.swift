import BassetEntityComponent
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Groups ended taps into bursts on one control. UIKit-free so the grouping is testable
/// without a `UITouch`; identity is whatever object the caller keys a tap on.
struct TapBurstDetector {
    struct Tap {
        let view: ObjectIdentifier?
        let viewClass: String?
        let identifier: String?
        let label: String?
        let x: Double
        let y: Double
        let at: UInt64
    }

    struct Burst {
        let id: UInt32
        private(set) var taps: [Tap]
        private(set) var reported = false

        var first: Tap {
            taps[0]
        }

        var last: Tap {
            taps[taps.count - 1]
        }

        var centre: (x: Double, y: Double) {
            (
                taps.map(\.x).reduce(0, +) / Double(taps.count),
                taps.map(\.y).reduce(0, +) / Double(taps.count)
            )
        }

        var spanMicroseconds: UInt64 {
            last.at > first.at ? last.at - first.at : 0
        }

        fileprivate init(id: UInt32, tap: Tap) {
            self.id = id
            taps = [tap]
        }

        fileprivate mutating func add(_ tap: Tap) {
            taps.append(tap)
        }

        fileprivate mutating func markReported() {
            reported = true
        }
    }

    let threshold: Int
    let withinMicroseconds: UInt64
    let radiusPoints: Double

    private var open: [Burst] = []

    init(threshold: Int, withinMicroseconds: UInt64, radiusPoints: Double) {
        self.threshold = max(2, threshold)
        self.withinMicroseconds = withinMicroseconds
        self.radiusPoints = radiusPoints
    }

    private static func hasEnded(_ burst: Burst, by now: UInt64, within window: UInt64) -> Bool {
        burst.last.at + window < now
    }

    /// The burst this tap completes, the moment it reaches the threshold — nil for every other
    /// tap, including the ones that keep an already-reported burst going.
    mutating func record(_ tap: Tap) -> Burst? {
        let window = withinMicroseconds
        open.removeAll { !$0.reported && Self.hasEnded($0, by: tap.at, within: window) }

        guard let index = open.firstIndex(where: {
            !Self.hasEnded($0, by: tap.at, within: window) && belongs(tap, to: $0)
        }) else {
            open.append(Burst(id: EntityIdentity.next(), tap: tap))
            return nil
        }

        open[index].add(tap)
        guard open[index].taps.count == threshold else {
            return nil
        }

        open[index].markReported()
        return open[index]
    }

    /// Bursts whose last tap is older than the window, removed — the reported ones come back so
    /// their final count can be written.
    mutating func expire(now: UInt64) -> [Burst] {
        let window = withinMicroseconds
        let ended = open.filter { Self.hasEnded($0, by: now, within: window) }
        open.removeAll { Self.hasEnded($0, by: now, within: window) }
        return ended.filter(\.reported)
    }

    private func belongs(_ tap: Tap, to burst: Burst) -> Bool {
        if let view = tap.view, let burstView = burst.first.view, view != burstView {
            return false
        }

        let centre = burst.centre
        return hypot(tap.x - centre.x, tap.y - centre.y) <= radiusPoints
    }
}

/// The same control tapped again and again — a tap that did nothing, reported by the finger
/// rather than by anyone filing a bug. Raises a fault so the instruments that answer one
/// (thread snapshot) capture what the process was doing while the taps went nowhere.
final class RepeatedTaps: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let taps: Int
        let withinMs: Int
        let radiusPoints: Double
    }

    static let id: InstrumentID = .repeatedTaps

    static let defaultConfig: Config = .init(taps: 3, withinMs: 5000, radiusPoints: 44)

    private let detector: Mutex<TapBurstDetector>
    private let targets: Mutex<TouchTargets> = .init(TouchTargets())
    private let clock: Clock = .init()

    init(config: Config) {
        detector = .init(TapBurstDetector(
            threshold: config.taps,
            withinMicroseconds: UInt64(max(0, config.withinMs)) * 1000,
            radiusPoints: config.radiusPoints
        ))
    }

    private static func describe(_ burst: TapBurstDetector.Burst, into out: inout Readings) {
        let centre = burst.centre
        out.put(.occurrenceCount(UInt64(burst.taps.count)))
        out.put(.windowNanoseconds(burst.spanMicroseconds * 1000))
        out.put(.originXPoints(centre.x))
        out.put(.originYPoints(centre.y))
        if let viewClass = burst.first.viewClass {
            out.put(.runtimeClassName(viewClass))
        }
        if let identifier = burst.first.identifier {
            out.put(.accessibilityIdentifier(identifier))
        }
        if let label = burst.first.label {
            out.put(.accessibilityLabel(label))
        }
        out.put(.faultId(burst.id))
    }

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIWindow.self,
            #selector(UIWindow.sendEvent(_:))
        ) { [weak self] (_, argument: AnyObject?) in
            self?.received(argument, context)
        }

        context.flush(every: .seconds(1), into: .repeatedTaps) { [weak self] out, _ in
            guard let self else {
                return
            }

            let ended = detector.withLock { $0.expire(now: self.uptimeMicroseconds()) }
            guard let first = ended.first else {
                return
            }

            Self.describe(first, into: &out)
            for burst in ended.dropFirst() {
                out.also(.repeatedTaps) { more in Self.describe(burst, into: &more) }
            }
        }
        #endif
    }

    func stopObserving() {
        targets.withLock { $0 = TouchTargets() }
        detector.withLock { detector in
            detector = TapBurstDetector(
                threshold: detector.threshold,
                withinMicroseconds: detector.withinMicroseconds,
                radiusPoints: detector.radiusPoints
            )
        }
    }

    private func uptimeMicroseconds() -> UInt64 {
        clock.now().nanoseconds / 1000
    }

    #if canImport(UIKit)
    private func received(_ argument: AnyObject?, _ context: Context) {
        guard let event = argument as? UIEvent, event.type == .touches,
              let touches = event.allTouches
        else {
            return
        }

        for touch in touches {
            #if DEBUG
            if SyntheticTouches.contains(touch) {
                continue
            }
            #endif

            let key = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                targets.withLock { $0.began(key, on: TouchTarget.of(touch)) }
                continue
            case .cancelled:
                _ = targets.withLock { $0.ended(key) }
                continue
            case .ended:
                break
            default:
                continue
            }

            let target = targets.withLock { $0.ended(key) } ?? TouchTarget.of(touch)
            let location = touch.location(in: nil)
            let tap = TapBurstDetector.Tap(
                view: target?.identity,
                viewClass: target?.className,
                identifier: target?.accessibilityIdentifier,
                label: target?.accessibilityLabel,
                x: Double(location.x),
                y: Double(location.y),
                at: uptimeMicroseconds()
            )
            guard let burst = detector.withLock({ $0.record(tap) }) else {
                continue
            }

            let centre = burst.centre
            let window = touch.window
            context.emit(.repeatedTaps) { out in
                Self.describe(burst, into: &out)
                out.also(.viewHierarchy) { hier in
                    if let window {
                        ViewHierarchy.writeMatches(
                            at: CGPoint(x: centre.x, y: centre.y),
                            in: window,
                            parent: 0,
                            into: &hier
                        )
                    } else {
                        ViewHierarchy.write(
                            at: CGPoint(x: centre.x, y: centre.y),
                            parent: 0,
                            into: &hier
                        )
                    }
                    hier.tagEveryEntity(with: .faultId(burst.id))
                }
            }
            context.faultWithoutBlocking(.repeatedTaps, burst.id)
        }
    }
    #endif
}
