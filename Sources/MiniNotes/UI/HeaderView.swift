import AppKit

/// A label that lets clicks fall through (so the header stays draggable).
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 1pt separator line with a fixed height (NSBox separators size and orient themselves unpredictably).
final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.separator.setFill()
        bounds.fill()
    }
}

final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(symbol: String, tip: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        toolTip = tip
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .none
        refusesFirstResponder = true
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setSymbol(symbol)
    }

    private var active = false

    required init?(coder: NSCoder) { fatalError() }

    /// `active` tints the icon with the accent color (e.g. pinned).
    func setSymbol(_ name: String, active: Bool = false) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        self.active = active
        applyTheme()
    }

    func applyTheme() {
        contentTintColor = active ? Theme.accent : Theme.secondary
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = self.hovered ? Theme.hover.cgColor : nil
        }
    }
}

final class HeaderView: NSView {
    private let titleLabel = PassthroughLabel(labelWithString: "")
    private let separator = Hairline()
    private let left = NSStackView()
    private let right = NSStackView()

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        separator.alphaValue = 0
        for s in [left, right] { s.orientation = .horizontal; s.spacing = 2 }
        for v in [titleLabel, separator, left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        titleLabel.textColor = Theme.secondary
        separator.needsDisplay = true
        for b in left.arrangedSubviews + right.arrangedSubviews { (b as? HoverButton)?.applyTheme() }
    }

    func setButtons(left l: [NSView], right r: [NSView]) {
        l.forEach { left.addArrangedSubview($0) }
        r.forEach { right.addArrangedSubview($0) }
    }

    var title: String {
        get { titleLabel.stringValue }
        set { if titleLabel.stringValue != newValue { titleLabel.stringValue = newValue } }
    }

    func setSeparatorVisible(_ visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        guard separator.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            separator.animator().alphaValue = alpha
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
