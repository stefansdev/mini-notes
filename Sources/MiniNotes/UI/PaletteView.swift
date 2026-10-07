import AppKit

/// A secondary action on a row, triggered by a key combo while the row is selected (e.g. ⌘D).
struct PaletteAction {
    var title: String
    var keyLabel: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var run: () -> Void
}

struct PaletteItem {
    var title: String
    var subtitle: String = ""
    var accessory: String = ""
    var symbol: String = "doc.text"
    /// Shown instead of `symbol` when set (e.g. theme swatches).
    var image: NSImage? = nil
    /// Draws the title in this font (font picker).
    var titleFont: NSFont? = nil
    /// Starts selected when the palette opens.
    var isCurrent: Bool = false
    /// Runs when the row becomes selected (live preview).
    var preview: (() -> Void)? = nil
    var extraActions: [PaletteAction] = []
    var primaryTitle = "Open"
    var action: () -> Void
}

/// Raycast-style searchable list used for both "Browse Notes" (⌘P) and "Actions" (⌘K).
final class PaletteView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let field = NSTextField()
    let kind: String
    var onClose: (() -> Void)?
    /// Called when dismissed without choosing (Esc / click outside), before `onClose`.
    var onCancel: (() -> Void)?
    private let searchIcon = NSImageView()

    private let card = CardView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No results")
    private let hintLabel = NSTextField(labelWithString: "")
    private let hintSeparator = Hairline()
    private var hintHeight: NSLayoutConstraint!
    private let provider: (String) -> [PaletteItem]
    private var items: [PaletteItem] = []

    init(kind: String, placeholder: String, provider: @escaping (String) -> [PaletteItem]) {
        self.kind = kind
        self.provider = provider
        super.init(frame: .zero)
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.shadowOpacity = 0.18
        card.layer?.shadowRadius = 14
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let separator = Hairline()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        emptyLabel.font = .systemFont(ofSize: 13)

        let search = searchIcon
        search.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        search.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        self.placeholder = placeholder

        addSubview(card)
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.alignment = .right
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintHeight = hintSeparator.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: 0)
        for v in [search, field, separator, scroll, emptyLabel, hintSeparator, hintLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(v)
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            search.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            search.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),

            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hintSeparator.topAnchor),
            hintSeparator.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            hintSeparator.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            hintHeight,
            hintLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            hintLabel.centerYAnchor.constraint(equalTo: card.bottomAnchor, constant: -15),

            emptyLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 24),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var placeholder = ""
    /// Re-coloring reloads the table; don't treat that as the user picking a row.
    private var suppressPreview = false

    func applyTheme() {
        suppressPreview = true
        defer { suppressPreview = false }
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        emptyLabel.textColor = Theme.tertiary
        hintLabel.textColor = Theme.tertiary
        hintSeparator.needsDisplay = true
        searchIcon.contentTintColor = Theme.tertiary
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Theme.tertiary, .font: NSFont.systemFont(ofSize: 15),
        ])
        card.needsDisplay = true
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selected, byExtendingSelection: false)
    }

    func reload() {
        items = provider(field.stringValue)
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        if !items.isEmpty {
            let row = field.stringValue.isEmpty ? (items.firstIndex { $0.isCurrent } ?? 0) : 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateHint()
    }

    private func cancel() {
        onCancel?()
        onClose?()
    }

    /// Row actions like ⌘D / ⌘⌫ / ⇧⌘P act on the selected row before the menu bar sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let row = table.selectedRow
        if items.indices.contains(row),
           let action = items[row].extraActions.first(where: { $0.keyCode == event.keyCode && $0.modifiers == flags }) {
            action.run()
            refresh()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Re-queries the list, keeping the selection position.
    func refresh() {
        let row = table.selectedRow
        items = provider(field.stringValue)
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        if !items.isEmpty {
            let r = max(0, min(row, items.count - 1))
            suppressPreview = true
            table.selectRowIndexes([r], byExtendingSelection: false)
            suppressPreview = false
            table.scrollRowToVisible(r)
        }
        updateHint()
        window?.makeFirstResponder(field)
    }

    private func updateHint() {
        let row = table.selectedRow
        guard items.indices.contains(row), !items[row].extraActions.isEmpty else {
            hintLabel.stringValue = ""
            hintSeparator.isHidden = true
            hintHeight.constant = 0
            return
        }
        let item = items[row]
        let parts = ["↩ \(item.primaryTitle)"] + item.extraActions.map { "\($0.keyLabel) \($0.title)" }
        hintLabel.stringValue = parts.joined(separator: "    ")
        hintSeparator.isHidden = false
        hintHeight.constant = -30
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { cancel() }
    }

    // MARK: Keyboard

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): run(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func run(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        onClose?()
        item.action()
    }

    @objc private func clicked() { run(table.clickedRow) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if !suppressPreview, items.indices.contains(row) { items[row].preview?() }
        updateHint()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: PaletteCell.id, owner: nil) as? PaletteCell) ?? PaletteCell()
        cell.configure(items[row])
        return cell
    }
}

private final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.paletteBackground.setFill()
        path.fill()
        Theme.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.rowSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

private final class PaletteCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("PaletteCell")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        subtitle.font = .systemFont(ofSize: 12.5)
        accessory.font = .systemFont(ofSize: 12)
        accessory.alignment = .right
        for l in [title, subtitle, accessory] {
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            l.cell?.usesSingleLineMode = true
        }
        title.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(740), for: .horizontal)
        subtitle.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, title, subtitle, accessory] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: subtitle.trailingAnchor, constant: 12),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            accessory.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: PaletteItem) {
        icon.image = item.image ?? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.contentTintColor = Theme.secondary
        title.textColor = Theme.text
        title.font = item.titleFont ?? .systemFont(ofSize: 13.5, weight: .medium)
        subtitle.textColor = Theme.tertiary
        accessory.textColor = Theme.tertiary
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle
        accessory.stringValue = item.accessory
    }
}
