import AppKit

@MainActor
final class WindowBackgroundView: NSView {
    private let effectView = NSVisualEffectView()

    init(contentView: NSView) {
        super.init(frame: .zero)
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
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

    func apply(enabled: Bool, to window: NSWindow) {
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        window.titlebarAppearsTransparent = enabled
        effectView.isHidden = !enabled
    }
}
