import BassetEntityComponent
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum AppIcon {
    static let sidePoints: CGFloat = 32

    #if canImport(UIKit)
    static func reading() -> Readings? {
        guard let drawn = scaled(named: primaryName()),
              let data = drawn.image.pngData()
        else {
            return nil
        }

        var out = Readings(.appIcon)
        out.put(.imageFormat("png"))
        out.put(.formatWidthPixels(Int32(clamping: Int(drawn.pixels))))
        out.put(.formatHeightPixels(Int32(clamping: Int(drawn.pixels))))
        out.put(.screenScale(Float(drawn.scale)))
        out.put(.imageData(data))
        return out
    }

    private static func primaryName() -> String? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String]
        else {
            return nil
        }

        return files.last
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
    #else
    static func reading() -> Readings? {
        nil
    }
    #endif
}
