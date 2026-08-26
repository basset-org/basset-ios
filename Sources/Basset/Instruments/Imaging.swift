import BassetECS
import Foundation

/// Core Image renders, counted per destination, and the images built back out of a texture.
///
/// A `CIImage` places its origin at the bottom left and a Metal texture places its at the top
/// left, so every round trip through a texture flips the result. The two counts here are what
/// make that parity readable: an odd number of round trips between capture and output leaves
/// the output flipped, an even number leaves it upright.
final class ImagingRenderPasses: Streamable, PlainInstrument {
    private enum Slot {
        static let toTexture: TallySlot = .init(0)
        static let toPixelBuffer: TallySlot = .init(1)
        static let toBitmap: TallySlot = .init(2)
        static let toCGImage: TallySlot = .init(3)
        static let empty: TallySlot = .init(4)
        static let fromTexture: TallySlot = .init(5)
    }

    private struct Destination {
        let name: String
        let slot: TallySlot
        let selector: String
    }

    static let id: InstrumentID = .imagingRenderPasses
    static let entity = Entity.ID.imageRender
    static let tallySlots = 6

    private static let contextClassName = "CIContext"
    private static let imageClassName = "CIImage"
    private static let textureImageSelector = "initWithMTLTexture:options:"

    private static let destinations: [Destination] = [
        .init(
            name: "metalTexture",
            slot: Slot.toTexture,
            selector: "render:toMTLTexture:commandBuffer:bounds:colorSpace:"
        ),
        .init(
            name: "pixelBuffer",
            slot: Slot.toPixelBuffer,
            selector: "render:toCVPixelBuffer:"
        ),
        .init(
            name: "pixelBuffer",
            slot: Slot.toPixelBuffer,
            selector: "render:toCVPixelBuffer:bounds:colorSpace:"
        ),
        .init(
            name: "bitmap",
            slot: Slot.toBitmap,
            selector: "render:toBitmap:rowBytes:bounds:format:colorSpace:"
        ),
        .init(
            name: "cgImage",
            slot: Slot.toCGImage,
            selector: "createCGImage:fromRect:"
        ),
    ]

    init() {}

    static func write(
        _ tally: Tally,
        over elapsed: Context.FlushWindow,
        into out: inout Readings
    ) {
        let counted = [
            ("metalTexture", tally.take(Slot.toTexture)),
            ("pixelBuffer", tally.take(Slot.toPixelBuffer)),
            ("bitmap", tally.take(Slot.toBitmap)),
            ("cgImage", tally.take(Slot.toCGImage)),
        ]
        let empty = tally.take(Slot.empty)
        let fromTexture = tally.take(Slot.fromTexture)
        let rendered = counted.reduce(0) { $0 + $1.1 }

        guard rendered > 0 || fromTexture > 0 || empty > 0 else {
            return
        }

        out.put(.windowNanoseconds(elapsed.nanoseconds))
        out.put(.occurrenceCount(rendered))
        out.put(.textureBackedImageCount(fromTexture))
        if empty > 0 {
            out.put(.emptyResultCount(empty))
        }

        for (name, count) in counted where count > 0 {
            out.also(Self.entity) { destination in
                destination.put(.renderDestination(name))
                destination.put(.occurrenceCount(count))
            }
        }
    }

    func observe(_ context: Context) {
        guard let contextClass = objc_getClass(Self.contextClassName) as? AnyClass else {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: this app does not use Core Image"))
            }
            return
        }

        let hot = context.hotPath
        for destination in Self.destinations {
            _ = context.swizzle.afterFactory(
                contextClass,
                NSSelectorFromString(destination.selector)
            ) { _, produced in
                guard hot.isActive else {
                    return
                }

                hot.add(destination.slot)
                // Core Image answers a render it could not do with nothing, never an error.
                if produced == nil, destination.name == "cgImage" {
                    hot.add(Slot.empty)
                }
            }
        }

        if let imageClass = objc_getClass(Self.imageClassName) as? AnyClass {
            _ = context.swizzle.afterFactory(
                imageClass,
                NSSelectorFromString(Self.textureImageSelector)
            ) { _, _ in
                guard hot.isActive else {
                    return
                }

                hot.add(Slot.fromTexture)
            }
        }

        context.flush(every: .seconds(1)) { [tally = context.tally] out, elapsed in
            Self.write(tally, over: elapsed, into: &out)
        }
    }

    func stopObserving() {}
}
