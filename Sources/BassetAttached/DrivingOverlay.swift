import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
/// A window above the app saying Basset is driving it. Real fingers stop at it when asked;
/// synthetic touches never meet it, since they are delivered to the app's own key window,
/// and a screenshot never shows it, since only the key window is drawn.
@MainActor
enum DrivingOverlay {
    private final class OverlayWindow: UIWindow {
        var blocksTouches = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            blocksTouches ? self : nil
        }
    }

    private static var window: OverlayWindow?
    private static var label: UILabel?

    static func show(text: String, blocksTouches: Bool) -> Bool {
        guard let scene = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return false
        }

        let overlay = window ?? make(in: scene)
        overlay.blocksTouches = blocksTouches
        label?.text = text
        overlay.isHidden = false
        return true
    }

    static func hide() {
        window?.isHidden = true
        window = nil
        label = nil
    }

    /// An app left under a blocking overlay takes a force-quit to use again.
    nonisolated static func hideFromAnyThread() {
        DispatchQueue.main.async { hide() }
    }

    private static func make(in scene: UIWindowScene) -> OverlayWindow {
        let overlay = OverlayWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear

        let border = UIView(frame: overlay.bounds)
        border.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        border.layer.borderColor = UIColor.systemTeal.cgColor
        border.layer.borderWidth = 4
        border.isUserInteractionEnabled = false
        overlay.addSubview(border)

        let banner = UIView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.92)
        banner.layer.cornerRadius = 14
        banner.isUserInteractionEnabled = false
        overlay.addSubview(banner)

        let text = UILabel()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 13, weight: .semibold)
        text.textColor = .black
        text.textAlignment = .center
        text.numberOfLines = 2
        banner.addSubview(text)

        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            banner.topAnchor.constraint(
                equalTo: overlay.safeAreaLayoutGuide.topAnchor,
                constant: 6
            ),
            banner.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlay.leadingAnchor,
                constant: 24
            ),
            text.topAnchor.constraint(equalTo: banner.topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -6),
            text.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -14),
        ])

        window = overlay
        label = text
        return overlay
    }
}
#endif

#if DEBUG && !canImport(UIKit)
enum DrivingOverlay {
    static func hideFromAnyThread() {}
}
#endif
