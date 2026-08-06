import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The text size the user chose, and whether it is one of the accessibility
/// sizes.
///
/// Separate from `environment.accessibility` because it is not a flag and not
/// only an accessibility setting: every user has a text size, most have moved it
/// at some point, and the five accessibility sizes above the normal range are
/// where layouts stop fitting. A screen that is correct at `large` and clipped at
/// `accessibilityExtraExtraExtraLarge` is not a bug anybody sees on a development
/// device, because nobody develops at AX5.
///
/// `isAccessibilityCategory` is carried alongside the name rather than left for
/// the reader to derive: the boundary is where behaviour changes, and knowing the
/// category name means nothing without knowing which side of it the user is on.
final class DynamicType: StreamingInstrument {
    static let id: InstrumentWireID = .dynamicType
    static let entity = Entity.WireID.deviceSetting

    private var observer: NSObjectProtocol?

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        report(into: context)
        observer = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.report(into: context)
        }
        #endif
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    #if canImport(UIKit)
    private func report(into context: Context) {
        let category = UIApplication.shared.preferredContentSizeCategory
        context.emitIfChanged { out in
            // The raw value carries a `UICTContentSizeCategory` prefix nobody
            // outside UIKit reads. The suffix is the size the user picked.
            out.put(.textSizeCategory(Self.name(of: category)))
            out.put(.accessibilityTextSize(category.isAccessibilityCategory))
        }
    }

    /// Mapped from the constants rather than derived from the raw value. UIKit's
    /// values are Core Text abbreviations — `.large` is `UICTContentSizeCategoryL`
    /// and `.accessibilityExtraExtraExtraLarge` is `…AccessibilityXXXL` — so
    /// stripping the prefix yields `L` and `accessibilityXXXL`, which is what a
    /// reader would then be shown as the user's text size. A constant's value is
    /// not its symbol's name.
    static func name(of category: UIContentSizeCategory) -> String {
        switch category {
        case .extraSmall: "extraSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .extraLarge: "extraLarge"
        case .extraExtraLarge: "extraExtraLarge"
        case .extraExtraExtraLarge: "extraExtraExtraLarge"
        case .accessibilityMedium: "accessibilityMedium"
        case .accessibilityLarge: "accessibilityLarge"
        case .accessibilityExtraLarge: "accessibilityExtraLarge"
        case .accessibilityExtraExtraLarge: "accessibilityExtraExtraLarge"
        case .accessibilityExtraExtraExtraLarge: "accessibilityExtraExtraExtraLarge"
        case .unspecified: "unspecified"
        default: "unrecognised(\(category.rawValue))"
        }
    }

    #endif
}
