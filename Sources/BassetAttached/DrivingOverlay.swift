import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG && canImport(UIKit)
/// Synthetic touches and screenshots target the key window, so this window never meets either.
@MainActor
enum DrivingOverlay {
    private final class OverlayWindow: UIWindow {
        var blocksTouches = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard blocksTouches else {
                return nil
            }

            return super.hitTest(point, with: event) ?? self
        }
    }

    private static var window: OverlayWindow?
    private static var backdrop: UIView?
    private static var banner: UIView?
    private static var titleLabel: UILabel?
    private static var whyLabel: UILabel?
    private static var bannerLabel: UILabel?
    private static var cancelButton: UIButton?
    private static var onCancel: (() -> Void)?

    static func show(text: String, blocksTouches: Bool, onCancel: @escaping () -> Void) -> Bool {
        guard let scene = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else {
            return false
        }

        let overlay = window ?? make(in: scene)
        overlay.blocksTouches = blocksTouches
        Self.onCancel = onCancel
        whyLabel?.text = text
        bannerLabel?.text = text
        for view in [backdrop, titleLabel, whyLabel, cancelButton] {
            view?.isHidden = !blocksTouches
        }
        banner?.isHidden = blocksTouches
        overlay.isHidden = false
        return true
    }

    static func hide() {
        window?.isHidden = true
        window = nil
        backdrop = nil
        banner = nil
        titleLabel = nil
        whyLabel = nil
        bannerLabel = nil
        cancelButton = nil
        onCancel = nil
    }

    /// An app left under a blocking overlay takes a force-quit to use again.
    nonisolated static func hideFromAnyThread() {
        DispatchQueue.main.async { hide() }
    }

    private static func cancelTapped() {
        let handler = onCancel
        hide()
        handler?()
    }

    private static func shadow(_ label: UILabel) {
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 4
        label.layer.shadowOffset = .zero
    }

    private static func make(in scene: UIWindowScene) -> OverlayWindow {
        let overlay = OverlayWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear

        let black = UIView(frame: overlay.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        black.isUserInteractionEnabled = false
        overlay.addSubview(black)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center
        title.text = "Basset Attached"
        shadow(title)
        overlay.addSubview(title)

        let why = UILabel()
        why.translatesAutoresizingMaskIntoConstraints = false
        why.font = .systemFont(ofSize: 16, weight: .regular)
        why.textColor = UIColor.white.withAlphaComponent(0.8)
        why.textAlignment = .center
        why.numberOfLines = 0
        shadow(why)
        overlay.addSubview(why)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Cancel"
        configuration.baseBackgroundColor = .white
        configuration.baseForegroundColor = .black
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14,
            leading: 40,
            bottom: 14,
            trailing: 40
        )
        let cancel = UIButton(
            configuration: configuration,
            primaryAction: UIAction { _ in cancelTapped() }
        )
        cancel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(cancel)

        let strip = UIView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        strip.layer.cornerRadius = 14
        strip.isUserInteractionEnabled = false
        overlay.addSubview(strip)

        let stripText = UILabel()
        stripText.translatesAutoresizingMaskIntoConstraints = false
        stripText.font = .systemFont(ofSize: 13, weight: .semibold)
        stripText.textColor = .white
        stripText.textAlignment = .center
        stripText.numberOfLines = 2
        strip.addSubview(stripText)

        let safe = overlay.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -24),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
            why.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            why.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 32),
            why.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -32),
            cancel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            cancel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            strip.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            strip.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            strip.leadingAnchor.constraint(
                greaterThanOrEqualTo: overlay.leadingAnchor,
                constant: 24
            ),
            stripText.topAnchor.constraint(equalTo: strip.topAnchor, constant: 6),
            stripText.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -6),
            stripText.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 14),
            stripText.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -14),
        ])

        window = overlay
        backdrop = black
        banner = strip
        titleLabel = title
        whyLabel = why
        bannerLabel = stripText
        cancelButton = cancel
        return overlay
    }
}
#endif

#if DEBUG && !canImport(UIKit)
enum DrivingOverlay {
    static func hideFromAnyThread() {}
}
#endif
