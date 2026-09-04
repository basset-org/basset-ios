import BassetEntityComponent
import Foundation
#if canImport(CoreImage)
import CoreImage
#endif

/// IOSurfaces coming and going, and the app code that built each large Core Image image —
/// the two halves that say whether a surface is a decode, a wrapped buffer or a render cache.
final class ImagingSurfaces: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let thresholdMegapixels: Int
    }

    static let id: InstrumentID = .imagingSurfaces
    static let defaultConfig: Config = .init(thresholdMegapixels: 2)
    static let windowSeconds = 5
    /// Rows a window lists before folding the rest into a count.
    static let surfaceCeiling = 12
    static let imageCeiling = 24

    private static let minimumThresholdMegapixels = 1
    private static let maximumThresholdMegapixels = 200
    private static let imageClassName = "CIImage"
    private static let objectInitializers: [(selector: String, source: String)] = [
        ("initWithData:options:", "data"),
        ("initWithContentsOfURL:options:", "url"),
    ]

    private static let pointerInitializers: [(selector: String, source: String)] = [
        ("initWithCGImage:options:", "cgImage"),
        ("initWithCVPixelBuffer:options:", "pixelBuffer"),
    ]

    private let thresholdPixels: UInt64
    private let surfaces: Mutex<SurfaceLedger> = .init(SurfaceLedger())
    private let images: Mutex<LargeImageLedger> = .init(LargeImageLedger(ceiling: imageCeiling))

    /// Large images seen this window and not yet flushed, in the order they first appeared.
    var pendingImageKeys: [LargeImageLedger.Key] {
        images.withLock { $0.pending }
    }

    init(config: Config) {
        let megapixels = min(
            max(config.thresholdMegapixels, Self.minimumThresholdMegapixels),
            Self.maximumThresholdMegapixels
        )
        thresholdPixels = UInt64(megapixels) * 1000000
    }

    func observe(_ context: Context) {
        #if canImport(CoreImage)
        if let imageClass = objc_getClass(Self.imageClassName) as? AnyClass {
            var outcomes = [(source: String, outcome: SwizzleOutcome)]()
            for (selector, source) in Self.objectInitializers {
                let outcome = context.swizzle.afterInitializer(
                    imageClass,
                    NSSelectorFromString(selector),
                    takingTwoObjects: ()
                ) { [weak self] made in
                    self?.record(made, source: source)
                }
                outcomes.append((source, outcome))
            }
            for (selector, source) in Self.pointerInitializers {
                let outcome = context.swizzle.afterInitializer(
                    imageClass,
                    NSSelectorFromString(selector),
                    takingPointerAndObject: ()
                ) { [weak self] made in
                    self?.record(made, source: source)
                }
                outcomes.append((source, outcome))
            }
            for (source, outcome) in outcomes
                where outcome != .installed && outcome != .joinedExisting
            {
                context.emit(.imageSource) { out in
                    out.put(.imageSource(source))
                    out.put(.mechanismStatus("unavailable: hook \(outcome)"))
                }
            }
        } else {
            context.emit(.imageSource) { out in
                out.put(.mechanismStatus("unavailable: this app does not use Core Image"))
            }
        }
        #endif

        context
            .flush(every: .seconds(Self.windowSeconds),
                   into: .surfaceWindow)
            { [weak self] out, _ in
                guard let self else {
                    return
                }

                let window = surfaces.withLock {
                    $0.advance(to: VMRegionWalk.regions(tag: VMRegionWalk.ioSurfaceTag))
                }
                window.write(into: &out, ceiling: Self.surfaceCeiling)
                let drained = images.withLock { $0.drain() }
                for image in drained.built {
                    out.also(.imageSource) { row in image.write(into: &row) }
                }
                if drained.unlistedSizes > 0 {
                    out.also(.imageSource) { rest in
                        rest.put(.mechanismStatus(
                            "truncated: \(drained.unlistedSizes) more sizes"
                        ))
                    }
                }
            }
    }

    func stopObserving() {}

    /// Runs inside every CIImage initializer: one extent read, one lock, and a stack walk
    /// only the first time a source-and-size is seen in the window.
    private func record(_ made: AnyObject?, source: String) {
        #if canImport(CoreImage)
        guard let image = made as? CIImage else {
            return
        }
        guard let key = LargeImageLedger.Key(source: source, extent: image.extent),
              key.pixels >= thresholdPixels
        else {
            return
        }

        let isNew = images.withLock { $0.count(key) }
        guard isNew else {
            return
        }

        let callers = CallerStack.inAppImages(CallerStack.here())
        images.withLock { $0.attach(callers, to: key) }
        #endif
    }
}

/// The previous walk's surfaces, so this walk can say which appeared and which vanished.
struct SurfaceLedger {
    struct Window: Equatable {
        let live: [VMRegion]
        let appeared: [VMRegion]
        let vanished: [VMRegion]

        var liveBytes: UInt64 {
            live.reduce(0) { $0 &+ $1.residentBytes }
        }

        var appearedBytes: UInt64 {
            appeared.reduce(0) { $0 &+ $1.residentBytes }
        }

        var vanishedBytes: UInt64 {
            vanished.reduce(0) { $0 &+ $1.residentBytes }
        }

        /// The window row carries the counts; each surface that appeared gets a row of its
        /// own, largest first, so a 48 MB decode is told apart from twelve 4 MB tiles.
        func write(into out: inout Readings, ceiling: Int) {
            out.put(.regionCount(UInt32(live.count)))
            out.put(.residentBytes(liveBytes))
            out.put(.appearedCount(UInt32(appeared.count)))
            out.put(.appearedBytes(appearedBytes))
            out.put(.vanishedCount(UInt32(vanished.count)))
            out.put(.vanishedBytes(vanishedBytes))

            let largestFirst = appeared.sorted { $0.residentBytes > $1.residentBytes }
            for surface in largestFirst.prefix(ceiling) {
                out.also(.surface) { row in
                    row.put(.residentBytes(surface.residentBytes))
                }
            }
            guard largestFirst.count > ceiling else {
                return
            }

            out.also(.surface) { rest in
                rest
                    .put(
                        .mechanismStatus("truncated: \(largestFirst.count - ceiling) more surfaces")
                    )
            }
        }
    }

    private var previous: Set<VMRegion> = []

    mutating func advance(to regions: [VMRegion]) -> Window {
        let current = Set(regions)
        let window = Window(
            live: regions,
            appeared: regions.filter { !previous.contains($0) },
            vanished: previous.subtracting(current).sorted { $0.address < $1.address }
        )
        previous = current
        return window
    }
}

/// Large images built this window, keyed by where they came from and how big they are.
struct LargeImageLedger {
    struct Key: Hashable {
        let source: String
        let width: Int32
        let height: Int32

        var pixels: UInt64 {
            UInt64(max(width, 0)) * UInt64(max(height, 0))
        }

        init(source: String, width: Int32, height: Int32) {
            self.source = source
            self.width = width
            self.height = height
        }

        /// `CGRect.infinite` passes `isFinite` and overflows `Int32`, so the bound is explicit.
        init?(source: String, extent: CGRect) {
            guard extent.width > 0, extent.height > 0,
                  extent.width <= CGFloat(Int32.max), extent.height <= CGFloat(Int32.max)
            else {
                return nil
            }

            self.init(source: source, width: Int32(extent.width), height: Int32(extent.height))
        }
    }

    struct Built: Equatable {
        let key: Key
        let count: UInt64
        let callers: [UInt64]

        func write(into out: inout Readings) {
            out.put(.imageSource(key.source))
            out.put(.formatWidthPixels(key.width))
            out.put(.formatHeightPixels(key.height))
            out.put(.occurrenceCount(count))
            for frame in callers {
                out.put(.frameAddress(frame))
            }
        }
    }

    struct Drained {
        let built: [Built]
        let unlistedSizes: Int
    }

    private let ceiling: Int
    private var counts: [Key: UInt64] = [:]
    private var callers: [Key: [UInt64]] = [:]
    private var order: [Key] = []
    private var unlisted: Set<Key> = []

    var pending: [Key] {
        order
    }

    init(ceiling: Int = 24) {
        self.ceiling = ceiling
    }

    /// True the first time a key is seen this window and there is room for it: the caller's
    /// cue to walk the stack once. Past the ceiling a new size is counted, never walked.
    mutating func count(_ key: Key) -> Bool {
        if let seen = counts[key] {
            counts[key] = seen + 1
            return false
        }
        guard order.count < ceiling else {
            unlisted.insert(key)
            return false
        }

        counts[key] = 1
        order.append(key)
        return true
    }

    mutating func attach(_ frames: [UInt64], to key: Key) {
        callers[key] = frames
    }

    mutating func drain() -> Drained {
        let built = order.map { key in
            Built(key: key, count: counts[key] ?? 0, callers: callers[key] ?? [])
        }
        let drained = Drained(built: built, unlistedSizes: unlisted.count)
        counts.removeAll()
        callers.removeAll()
        order.removeAll()
        unlisted.removeAll()
        return drained
    }
}
