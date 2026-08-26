import BassetECS
import Foundation

/// Core Image renders into a Metal texture, and the images built back out of one.
///
/// A round trip flips the image: `CIImage` puts its origin bottom left, a texture top left.
final class ImagingRenderPasses: Streamable, PlainInstrument {
    private enum Slot {
        static let toTexture: TallySlot = .init(0)
        static let fromTexture: TallySlot = .init(1)
    }

    static let id: InstrumentID = .imagingRenderPasses
    static let entity = Entity.ID.imageRender
    static let tallySlots = 2

    private static let contextClassName = "CIContext"
    private static let imageClassName = "CIImage"
    private static let renderSelector = "render:toMTLTexture:commandBuffer:bounds:colorSpace:"
    private static let imageSelector = "imageWithMTLTexture:options:"

    init() {}

    static func write(
        _ tally: Tally,
        over elapsed: Context.FlushWindow,
        into out: inout Readings
    ) {
        let rendered = tally.take(Slot.toTexture)
        let built = tally.take(Slot.fromTexture)
        guard rendered > 0 || built > 0 else {
            return
        }

        out.put(.windowNanoseconds(elapsed.nanoseconds))
        out.put(.renderDestination("metalTexture"))
        out.put(.occurrenceCount(rendered))
        out.put(.textureBackedImageCount(built))
    }

    func observe(_ context: Context) {
        guard let contextClass = objc_getClass(Self.contextClassName) as? AnyClass,
              let imageClass = objc_getClass(Self.imageClassName) as? AnyClass
        else {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: this app does not use Core Image"))
            }
            return
        }

        let hot = context.hotPath
        let rendering = context.swizzle.after(
            contextClass,
            NSSelectorFromString(Self.renderSelector),
            takingThreeObjectsRectAndPointer: ()
        ) { _ in
            guard hot.isActive else {
                return
            }

            hot.add(Slot.toTexture)
        }

        let building = context.swizzle.afterFactory(
            imageClass,
            NSSelectorFromString(Self.imageSelector),
            takingTwoObjects: (),
            kind: .type
        ) { _, _, _, made in
            // Core Image answers a texture it cannot wrap with nothing, not an error.
            guard hot.isActive, made != nil else {
                return
            }

            hot.add(Slot.fromTexture)
        }

        // Reported rather than discarded: a hook the runtime refused counts nothing, and a
        // zero that means "never looked" reads exactly like a zero that means "never ran".
        for (side, outcome) in [("render", rendering), ("image", building)]
            where outcome != .installed && outcome != .joinedExisting
        {
            context.emit { out in
                out.put(.mechanismStatus("unavailable: \(side) hook \(outcome)"))
            }
        }

        context.flush(every: .seconds(1)) { [tally = context.tally] out, elapsed in
            Self.write(tally, over: elapsed, into: &out)
        }
    }

    func stopObserving() {}
}
