import BassetEntityComponent
import Foundation
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

/// Whether a screenshot may leave the device: always for a machine attached over the cable,
/// and for the control plane only when the app's configuration said so.
enum ScreenshotPolicy {
    private static let remote: Mutex<Bool> = .init(false)

    static var isPermitted: Bool {
        AttachedBridge.channel != nil || remote.withLock { $0 }
    }

    static func allowRemote(_ allowed: Bool) {
        remote.withLock { $0 = allowed }
    }
}

/// The key window drawn into an image, once, when a request asks for it.
public final class Screenshot: Snapshotable, PlainInstrument {
    #if canImport(UIKit)
    private struct Captured {
        let image: UIImage
        let scale: CGFloat
    }

    private struct Encoded {
        let data: Data
        let format: String
        let widthPixels: Int
        let heightPixels: Int
    }

    private static func captureOnMain() -> Captured? {
        if Thread.isMainThread {
            return draw()
        }

        let box = Mutex<Captured?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let captured = draw()
            box.withLock { $0 = captured }
            done.signal()
        }
        guard done.wait(timeout: .now() + mainThreadWait) == .success else {
            return nil
        }

        return box.withLock { $0 }
    }

    private static func draw() -> Captured? {
        let windows = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            return nil
        }

        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = window.screen.scale
        // A window has no transparency; an alpha channel doubles the decode footprint for nothing.
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        return Captured(image: image, scale: window.screen.scale)
    }

    /// HEIC first; halves the image until it fits the budget rather than dropping it. The
    /// bitmap is re-drawn without an alpha channel before encoding: `UIImage.heicData` keeps
    /// whatever alpha the source CGImage carries, and ImageIO logs on every opaque image saved
    /// with one.
    private static func encode(_ original: UIImage) -> Encoded? {
        var image = original
        for _ in 0 ..< 3 {
            if let opaque = opaqueBitmap(of: image) {
                if let heic = encodeImage(opaque, type: "public.heic"),
                   heic.count <= imageBudgetBytes
                {
                    return Encoded(
                        data: heic,
                        format: "heic",
                        widthPixels: opaque.width,
                        heightPixels: opaque.height
                    )
                }
                if let jpeg = encodeImage(opaque, type: "public.jpeg"),
                   jpeg.count <= imageBudgetBytes
                {
                    return Encoded(
                        data: jpeg,
                        format: "jpeg",
                        widthPixels: opaque.width,
                        heightPixels: opaque.height
                    )
                }
            }
            image = halved(image)
        }
        return nil
    }

    private static func opaqueBitmap(of image: UIImage) -> CGImage? {
        guard let source = image.cgImage else {
            return nil
        }

        let width = source.width
        let height = source.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else {
            return nil
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodeImage(_ image: CGImage, type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
        else {
            return nil
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality as String: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    private static func halved(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.width / 2, height: image.size.height / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
    #endif

    public static let id: InstrumentID = .screenshot

    /// A hung main thread cannot draw; the reading says so rather than waiting on it.
    static let mainThreadWait: DispatchTimeInterval = .seconds(2)
    /// Held under the h2 transport's waiting bound: a batch above it is evicted whole on the
    /// first failed post, so a larger image could never survive one retry.
    static let imageBudgetBytes = HTTP2Channel.maxWaitingBytes / 2
    static let refusal = "refused: screenshots run only while a machine is attached, "
        + "or when Config.allowsScreenshots is set"

    public init() {}

    /// Never suggested: a screenshot is taken when asked for, not because an app was attached.
    public static func relevance(_ registries: Registries) -> Relevance {
        .notRelevant
    }

    /// Stamped after the draw and the encode, so the reading's time is the image's and it
    /// lands in order behind whatever ran while the image was being made.
    public func reading() -> Readings {
        guard ScreenshotPolicy.isPermitted else {
            return status(Self.refusal)
        }

        #if canImport(UIKit)
        guard let captured = Self.captureOnMain() else {
            return status(
                "unavailable: the main thread did not draw within 2 s, or there is no key window"
            )
        }
        guard let encoded = Self.encode(captured.image) else {
            return status("unavailable: the image could not be encoded under the frame ceiling")
        }

        var out = Readings(.screenshot)
        out.put(.imageFormat(encoded.format))
        out.put(.formatWidthPixels(Int32(clamping: encoded.widthPixels)))
        out.put(.formatHeightPixels(Int32(clamping: encoded.heightPixels)))
        out.put(.screenScale(Float(captured.scale)))
        out.put(.imageData(encoded.data))
        return out
        #else
        return status("unavailable: no screen to draw on this platform")
        #endif
    }

    private func status(_ text: String) -> Readings {
        var out = Readings(.screenshot)
        out.put(.mechanismStatus(text))
        return out
    }
}
