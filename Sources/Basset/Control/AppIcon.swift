import BassetEntityComponent
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if DEBUG
enum AppIcon {
    private struct Encoded {
        let png: Data
        let pixels: CGFloat
        let scale: CGFloat
    }

    static let sidePoints: CGFloat = 32

    #if canImport(UIKit)
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var encodedByName: [String: Encoded] = [:]

    static func reading() -> Readings? {
        guard let name = iconName(), let encoded = encoded(named: name) else {
            return nil
        }

        var out = Readings(.appIcon)
        out.put(.imageFormat("png"))
        out.put(.formatWidthPixels(Int32(clamping: Int(encoded.pixels))))
        out.put(.formatHeightPixels(Int32(clamping: Int(encoded.pixels))))
        out.put(.screenScale(Float(encoded.scale)))
        out.put(.imageData(encoded.png))
        return out
    }

    private static func encoded(named name: String) -> Encoded? {
        if let held = lock.withLock({ encodedByName[name] }) {
            return held
        }
        guard let drawn = scaled(named: name), let png = drawn.image.pngData() else {
            return nil
        }

        let fresh = Encoded(png: png, pixels: drawn.pixels, scale: drawn.scale)
        lock.withLock { encodedByName[name] = fresh }
        return fresh
    }

    private static func iconName() -> String? {
        if let alternate = alternateIconName() {
            return alternate
        }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
        else {
            return nil
        }

        return (primary["CFBundleIconFiles"] as? [String])?.last
            ?? primary["CFBundleIconName"] as? String
    }

    private static func alternateIconName() -> String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIApplication.shared.alternateIconName }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { UIApplication.shared.alternateIconName }
        }
    }

    private static func scaled(named name: String?)
        -> (image: UIImage, pixels: CGFloat, scale: CGFloat)?
    {
        guard let name, let source = UIImage(named: name) else {
            return nil
        }

        let scale = min(source.scale, 2)
        let size = CGSize(width: sidePoints, height: sidePoints)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        return (image, sidePoints * scale, scale)
    }
    #elseif canImport(AppKit)
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var encoded: Encoded??

    static func reading() -> Readings? {
        let held = lock.withLock { () -> Encoded?? in
            if encoded == nil {
                encoded = .some(rendered())
            }
            return encoded
        }
        guard let held, let icon = held else {
            return nil
        }

        var out = Readings(.appIcon)
        out.put(.imageFormat("png"))
        out.put(.formatWidthPixels(Int32(clamping: Int(icon.pixels))))
        out.put(.formatHeightPixels(Int32(clamping: Int(icon.pixels))))
        out.put(.screenScale(Float(icon.scale)))
        out.put(.imageData(icon.png))
        return out
    }

    private static func rendered() -> Encoded? {
        // AppKit hands every process a generic icon; only a bundle that declares one
        // has an icon worth sending.
        let info = Bundle.main.infoDictionary
        guard info?["CFBundleIconFile"] != nil || info?["CFBundleIconName"] != nil,
              let source = NSImage(named: NSImage.applicationIconName)
        else {
            return nil
        }

        let scale: CGFloat = 2
        let pixels = Int(sidePoints * scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return Encoded(png: png, pixels: CGFloat(pixels), scale: scale)
    }
    #else
    static func reading() -> Readings? {
        nil
    }
    #endif
}
#endif
