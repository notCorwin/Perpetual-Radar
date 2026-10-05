import AppKit

@MainActor
final class WindowBackgroundView: NSView {
    private let effectView = NSVisualEffectView()

    init(contentView: NSView) {
        super.init(frame: .zero)
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isHidden = true
        for view in [effectView, contentView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    func apply(enabled: Bool, opacity: Double, to window: NSWindow) -> Bool {
        let transparent = enabled && opacity < 1
        window.isOpaque = !transparent
        // Like Ghostty, retain a minimal window fill for correct native compositing.
        // The WebKit theme background remains the only visible tint layer.
        window.backgroundColor = transparent ? .white.withAlphaComponent(0.001) : .windowBackgroundColor
        window.titlebarAppearsTransparent = transparent
        let nativeBlur = WindowServerBlur.apply(radius: transparent ? WindowServerBlur.radius : 0, to: window)
        // Standard AppKit materials add their own tint, so reserve them for fallback.
        effectView.isHidden = !transparent || nativeBlur
        window.invalidateShadow()
        return nativeBlur
    }
}
