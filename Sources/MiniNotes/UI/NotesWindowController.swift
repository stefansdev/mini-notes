import AppKit
import UniformTypeIdentifiers
import Carbon.HIToolbox

/// Fills itself with a color (drawn, not a layer color, so it composites in order with siblings).
final class ColorView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.fill()
    }
}

final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    let panel: NotesPanel
    let textView: NoteTextView
    var openSettings: (() -> Void)?

    private let styler: MarkdownStyler
    private let layout = MarkdownLayoutManager()
    private let root = NSVisualEffectView()
    private let header = HeaderView()
    private let scrollView = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var pinButton: HoverButton!
    /// Solid background for editor themes (the System theme uses vibrancy instead).
    private let themeBackground = ColorView()
    private var palette: PaletteView?
    private(set) var currentID: String?
    private var cursorMemory: [String: NSRange] = [:]
    /// Folded heading positions per note, for this session.
    private var foldMemory: [String: Set<Int>] = [:]
    private var countWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    private var visibilityToken = 0
    private var store: NotesStore { .shared }

    override init() {
        styler = MarkdownStyler(baseSize: Prefs.fontSize)
        let rect = NSRect(x: 0, y: 0, width: 560, height: 540)
        panel = NotesPanel(contentRect: rect,
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: rect.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = NoteTextView(frame: rect, textContainer: container)
        super.init()
        storage.delegate = styler
        layout.bodyFont = styler.body
        styler.onCharactersEdited = { [weak layout] range, delta in layout?.adjustFolds(edited: range, delta: delta) }
        configurePanel()
        configureTextView()
        buildLayout()
        openInitialNote()
        applyTheme()
        NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        NotificationCenter.default.addObserver(forName: .editorSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEditorSettings() }
        }
        NotificationCenter.default.addObserver(forName: .notesChangedOnDisk, object: nil, queue: .main) { [weak self] note in
            let ids = note.userInfo?["ids"] as? Set<String> ?? []
            MainActor.assumeIsolated { self?.notesChangedOnDisk(ids) }
        }
    }

    /// Another device (via iCloud) or app changed files: refresh what's on screen.
    private func notesChangedOnDisk(_ ids: Set<String>) {
        if let id = currentID {
            if let note = store.note(id) {
                if ids.contains(id), note.text != textView.string {
                    let sel = textView.selectedRange()
                    let length = (note.text as NSString).length
                    textView.string = note.text
                    if let ts = textView.textStorage { styler.flush(ts) }
                    textView.undoManager?.removeAllActions()
                    textView.setSelectedRange(NSRange(location: min(sel.location, length), length: 0))
                    header.title = note.title
                    updateCounts()
                }
            } else {
                currentID = nil
                if let next = store.byModified.first { open(next.id) } else { open(store.create().id) }
            }
        }
        palette?.reload()
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        // On every desktop (Space) and over full-screen apps, so switching desktops never leaves it behind.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = NSSize(width: 340, height: 240)
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.level = Prefs.floatOnTop ? .floating : .normal
        let restored = panel.setFrameUsingName("MiniNotesWindow")
        if !restored || panel.frame.width < panel.minSize.width || panel.frame.height < panel.minSize.height {
            panel.setContentSize(NSSize(width: 560, height: 540))
            panel.center()
        }
        panel.setFrameAutosaveName("MiniNotesWindow")
    }

    private func configureTextView() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.insertionPointColor = Theme.accent
        tv.font = styler.body
        tv.defaultParagraphStyle = styler.bodyPara
        tv.typingAttributes = styler.baseAttributes
        tv.onEscape = { [weak self] in self?.handleEscape() }
    }

    private func buildLayout() {
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        panel.contentView = root
        themeBackground.frame = root.bounds
        themeBackground.autoresizingMask = [.width, .height]
        root.addSubview(themeBackground)

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.tertiary
        footer.alignment = .right

        let browse = HoverButton(symbol: "list.bullet", tip: "Browse Notes  ⌘P", target: self, action: #selector(browseNotes(_:)))
        let new = HoverButton(symbol: "square.and.pencil", tip: "New Note  ⌘N", target: self, action: #selector(newNote(_:)))
        pinButton = HoverButton(symbol: "pin", tip: "Float on Top  ⇧⌘F", target: self, action: #selector(toggleFloat(_:)))
        let more = HoverButton(symbol: "ellipsis", tip: "Actions  ⌘K", target: self, action: #selector(showActions(_:)))
        header.setButtons(left: [browse], right: [new, pinButton, more])
        applyFloat()

        for v in [scrollView, header, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
        ])
        root.layoutSubtreeIfNeeded()
        updateInsets()
    }

    /// Keeps a comfortable reading width on wide windows.
    private func updateInsets() {
        let width = scrollView.contentSize.width
        let maxWidth = Prefs.lineWidth > 0 ? Prefs.lineWidth : .greatestFiniteMagnitude
        let side = max(24, ((width - maxWidth) / 2).rounded())
        textView.textContainerInset = NSSize(width: side, height: 6)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
    }

    private func openInitialNote() {
        if let id = Prefs.lastNoteID, store.note(id) != nil {
            open(id)
        } else if let first = store.byModified.first {
            open(first.id)
        } else {
            open(store.create().id)
        }
    }

    // MARK: - Visibility

    func toggle() {
        if panel.isVisible, panel.isKeyWindow, NSApp.isActive {
            hide()
        } else {
            show()
        }
    }

    func show() {
        visibilityToken += 1
        store.refreshFromDisk()
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(palette?.field ?? textView)
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide(hideApp: Bool = true) {
        store.flush()
        if palette?.kind == "themes" || palette?.kind == "fonts" {
            palette?.onCancel?()
            closePalette()
        }
        guard panel.isVisible else { return }
        visibilityToken += 1
        let token = visibilityToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.visibilityToken else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                let others = NSApp.windows.contains { $0 !== self.panel && $0.isVisible && $0.styleMask.contains(.titled) }
                if hideApp, !others { NSApp.hide(nil) }
            }
        })
    }

    private func handleEscape() {
        if palette != nil { closePalette() } else { hide() }
    }

    // MARK: - Notes

    func open(_ id: String) {
        if let current = currentID, current != id {
            cursorMemory[current] = textView.selectedRange()
            foldMemory[current] = Set(layout.folds.keys)
            store.discardIfBlank(current)
        }
        guard let note = store.note(id) else { return }
        currentID = id
        Prefs.lastNoteID = id
        textView.string = note.text
        if let ts = textView.textStorage { styler.flush(ts) }
        layout.setFolds(foldMemory[id] ?? [])
        textView.undoManager?.removeAllActions()
        textView.typingAttributes = styler.baseAttributes
        let length = (note.text as NSString).length
        var sel = cursorMemory[id] ?? NSRange(location: length, length: 0)
        if NSMaxRange(sel) > length { sel = NSRange(location: length, length: 0) }
        textView.setSelectedRange(sel)
        textView.scrollRangeToVisible(sel)
        textView.needsDisplay = true
        header.title = note.title
        updateCounts()
    }

    private func createNote(text: String = "") {
        let note = store.create(text: text)
        open(note.id)
        show()
    }

    func reloadFolder() {
        currentID = nil
        cursorMemory = [:]
        openInitialNote()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        if let ts = textView.textStorage { styler.flush(ts) }
        guard let id = currentID else { return }
        store.update(id, text: textView.string)
        header.title = store.note(id)?.title ?? "Untitled"
        scheduleCounts()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let ts = textView.textStorage else { return }
        let apply = { [weak self] in
            guard let self, let ts = self.textView.textStorage else { return }
            let sel = self.textView.selectedRange()
            guard NSMaxRange(sel) <= ts.length else { return }
            // Moving into folded text (arrow keys, Find…) unfolds it.
            if self.layout.unfold(containing: sel.location) || self.layout.unfold(containing: NSMaxRange(sel)) {
                self.textView.needsDisplay = true
                self.textView.refreshFoldGutter()
            }
            self.layout.activate(ts.mutableString.paragraphRange(for: sel))
        }
        if ts.editedMask.isEmpty { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: - Footer

    private func scheduleCounts() {
        countWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateCounts() }
        countWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func updateCounts() {
        guard flashWork == nil else { return }
        let text = textView.string
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let chars = text.count
        footer.textColor = Theme.tertiary
        footer.stringValue = chars == 0 ? "" : "\(words) \(words == 1 ? "word" : "words")  ·  \(chars) \(chars == 1 ? "character" : "characters")"
    }

    /// Footer message from the updater; empty restores the word count.
    func showStatus(_ text: String) {
        if text.isEmpty { flashWork = nil; updateCounts() } else { flash(text, duration: 6) }
    }

    private func flash(_ message: String) { flash(message, duration: 1.6) }

    private func flash(_ message: String, duration: Double) {
        flashWork?.cancel()
        footer.textColor = Theme.secondary
        footer.stringValue = message
        let work = DispatchWorkItem { [weak self] in
            self?.flashWork = nil
            self?.updateCounts()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Palette

    /// Re-colors everything for the current theme.
    func applyTheme() {
        panel.appearance = Theme.appearance
        if let bg = Theme.background {
            themeBackground.isHidden = false
            themeBackground.color = bg
        } else {
            themeBackground.isHidden = true
        }
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        if let ts = textView.textStorage {
            ts.beginEditing()
            styler.styleAll(ts)
            ts.endEditing()
        }
        textView.typingAttributes = styler.baseAttributes
        textView.needsDisplay = true
        header.applyTheme()
        footer.textColor = flashWork == nil ? Theme.tertiary : Theme.secondary
        palette?.applyTheme()
    }

    #if DEBUG
    var debugPalette: PaletteView? { palette }
    #endif

    @objc func chooseFont(_ sender: Any?) {
        let original = Prefs.fontFamily
        func set(_ id: String) {
            Prefs.fontFamily = id
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil)
        }
        present(kind: "fonts", placeholder: "Search fonts…") { query in
            let terms = query.split(separator: " ").map(String.init)
            let choices = FontLibrary.builtInText.map { ($0, "Built in") } + FontLibrary.bundledText.map { ($0, "Included") }
            return choices.filter { choice, _ in
                terms.allSatisfy { choice.name.range(of: $0, options: .caseInsensitive) != nil }
            }.map { choice, group in
                PaletteItem(title: choice.name, accessory: choice.id == original ? "Current" : group,
                            symbol: "textformat", titleFont: FontLibrary.textFont(choice.id, size: 14),
                            isCurrent: choice.id == original,
                            preview: { set(choice.id) }, primaryTitle: "Use Font", action: { set(choice.id) })
            }
        }
        palette?.onCancel = { set(original) }
    }

    @objc func chooseTheme(_ sender: Any?) {
        let original = ThemeManager.shared.selectedID
        present(kind: "themes", placeholder: "Search themes…") { query in
            let ids = [Themes.system] + Themes.families.map(\.id) + Themes.all.map(\.id)
            let terms = query.split(separator: " ").map(String.init)
            return ids.filter { id in
                terms.allSatisfy { Themes.name(id).range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }.map { id in
                let kind = id == Themes.system ? "Follows macOS"
                    : Themes.family(id) != nil ? "Light + Dark"
                    : (Themes.spec(id)?.dark == true ? "Dark" : "Light")
                return PaletteItem(title: Themes.name(id), accessory: id == original ? "Current" : kind,
                                   symbol: "circle.lefthalf.filled", image: Themes.swatch(id), isCurrent: id == original,
                                   preview: { ThemeManager.shared.select(id, persist: false) },
                                   action: { ThemeManager.shared.select(id) })
            }
        }
        palette?.onCancel = { ThemeManager.shared.select(original) }
    }

    private func present(kind: String, placeholder: String, provider: @escaping (String) -> [PaletteItem]) {
        if !panel.isVisible { show() }
        if palette?.kind == kind {
            palette?.onCancel?()
            closePalette()
            return
        }
        palette?.onCancel?()
        palette?.removeFromSuperview()
        let p = PaletteView(kind: kind, placeholder: placeholder, provider: provider)
        p.onClose = { [weak self] in self?.closePalette() }
        p.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: header.bottomAnchor),
            p.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            p.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        palette = p
        p.reload()
        panel.makeFirstResponder(p.field)
    }

    private func closePalette() {
        guard let p = palette else { return }
        p.removeFromSuperview()
        palette = nil
        panel.makeFirstResponder(textView)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "Just now" : relative.localizedString(for: date, relativeTo: Date())
    }

    @objc func browseNotes(_ sender: Any?) {
        present(kind: "notes", placeholder: "Search notes…") { [weak self] query in
            guard let self else { return [] }
            let terms = query.split(separator: " ").map(String.init)
            let matching = self.store.byModified.filter { note in
                terms.allSatisfy { note.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            // Pinned notes first (in pin order), then everything else by last edit.
            let pinned = self.store.pinned.compactMap { id in matching.first { $0.id == id } }
            let rest = matching.filter { !self.store.isPinned($0.id) }
            var items = (pinned + rest).map { note -> PaletteItem in
                let isPinned = self.store.isPinned(note.id)
                let id = note.id
                return PaletteItem(
                    title: note.title, subtitle: note.preview, accessory: Self.ago(note.modified),
                    symbol: isPinned ? "pin.fill" : (id == self.currentID ? "doc.text.fill" : "doc.text"),
                    extraActions: [
                        PaletteAction(title: isPinned ? "Unpin" : "Pin", keyLabel: "⇧⌘P", keyCode: UInt16(kVK_ANSI_P),
                                      modifiers: [.command, .shift]) { [weak self] in self?.store.togglePin(id) },
                        PaletteAction(title: "Duplicate", keyLabel: "⌘D", keyCode: UInt16(kVK_ANSI_D),
                                      modifiers: .command) { [weak self] in self?.duplicate(id, open: false) },
                        PaletteAction(title: "Delete", keyLabel: "⌘⌫", keyCode: UInt16(kVK_Delete),
                                      modifiers: .command) { [weak self] in self?.confirmDelete(id) },
                    ]) { [weak self] in
                    self?.open(id)
                }
            }
            let q = query.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                items.append(PaletteItem(title: "Create “\(q)”", symbol: "plus") { [weak self] in
                    self?.createNote(text: "# \(q)\n")
                })
            }
            return items
        }
    }

    @objc func showActions(_ sender: Any?) {
        present(kind: "actions", placeholder: "Search actions…") { [weak self] query in
            guard let self else { return [] }
            let terms = query.split(separator: " ").map(String.init)
            return self.actionItems().filter { item in
                terms.allSatisfy { item.title.range(of: $0, options: .caseInsensitive) != nil }
            }
        }
    }

    private func actionItems() -> [PaletteItem] {
        func item(_ title: String, _ key: String, _ symbol: String, _ run: @escaping () -> Void) -> PaletteItem {
            PaletteItem(title: title, accessory: key, symbol: symbol, action: run)
        }
        func format(_ title: String, _ key: String, _ symbol: String, _ sel: Selector) -> PaletteItem {
            item(title, key, symbol) { [weak self] in
                guard let tv = self?.textView else { return }
                NSApp.sendAction(sel, to: tv, from: nil)
            }
        }
        let floating = Prefs.floatOnTop
        var top: [PaletteItem] = []
        if let release = Updater.shared.available {
            top.append(item("Install Update \(release.version)", "", "arrow.down.circle") { Updater.shared.promptInstall() })
        }
        return top + [
            item("New Note", "⌘N", "square.and.pencil") { [weak self] in self?.newNote(nil) },
            item("Browse Notes", "⌘P", "list.bullet") { [weak self] in self?.browseNotes(nil) },
            item("Duplicate Note", "⌘D", "plus.square.on.square") { [weak self] in self?.duplicateNote(nil) },
            item(store.isPinned(currentID ?? "") ? "Unpin Note" : "Pin Note", "⇧⌘P",
                 store.isPinned(currentID ?? "") ? "pin.slash" : "pin") { [weak self] in self?.togglePinCurrent(nil) },
            item("Copy Note", "⇧⌘C", "doc.on.doc") { [weak self] in self?.copyMarkdown(nil) },
            item("Export Note…", "⇧⌘E", "square.and.arrow.up") { [weak self] in self?.exportNote(nil) },
            item("Delete Note", "⇧⌘⌫", "trash") { [weak self] in self?.deleteNote(nil) },
            item(floating ? "Stop Floating on Top" : "Float on Top", "⇧⌘F", floating ? "pin.slash" : "pin") { [weak self] in self?.toggleFloat(nil) },
            item("Previous Note", "⌘[", "chevron.left") { [weak self] in self?.previousNote(nil) },
            item("Next Note", "⌘]", "chevron.right") { [weak self] in self?.nextNote(nil) },
            format("Heading 1", "⌥⌘1", "textformat.size.larger", #selector(NoteTextView.formatHeading1(_:))),
            format("Heading 2", "⌥⌘2", "textformat.size", #selector(NoteTextView.formatHeading2(_:))),
            format("Heading 3", "⌥⌘3", "textformat.size.smaller", #selector(NoteTextView.formatHeading3(_:))),
            format("Bold", "⌘B", "bold", #selector(NoteTextView.formatBold(_:))),
            format("Italic", "⌘I", "italic", #selector(NoteTextView.formatItalic(_:))),
            format("Strikethrough", "⇧⌘X", "strikethrough", #selector(NoteTextView.formatStrikethrough(_:))),
            format("Highlight", "⇧⌘H", "highlighter", #selector(NoteTextView.formatHighlight(_:))),
            format("Inline Code", "⌘E", "chevron.left.forwardslash.chevron.right", #selector(NoteTextView.formatInlineCode(_:))),
            format("Code Block", "⌥⌘C", "curlybraces", #selector(NoteTextView.formatCodeBlock(_:))),
            format("Link", "⌘L", "link", #selector(NoteTextView.formatLink(_:))),
            format("Bulleted List", "⇧⌘8", "list.bullet", #selector(NoteTextView.formatBulletList(_:))),
            format("Numbered List", "⇧⌘7", "list.number", #selector(NoteTextView.formatNumberedList(_:))),
            format("Checklist", "⇧⌘9", "checklist", #selector(NoteTextView.formatChecklist(_:))),
            format("Toggle Checkbox", "⌘↩", "checkmark.square", #selector(NoteTextView.toggleTask(_:))),
            format("Blockquote", "⇧⌘B", "text.quote", #selector(NoteTextView.formatQuote(_:))),
            format("Toggle Fold", "⌥⌘F", "chevron.down.circle", #selector(NoteTextView.toggleFoldAtCaret(_:))),
            format("Unfold All", "⇧⌥⌘F", "chevron.up.chevron.down", #selector(NoteTextView.unfoldAllSections(_:))),
            format("Move Line Up", "⌥⌘↑", "arrow.up", #selector(NoteTextView.moveLineUp(_:))),
            format("Move Line Down", "⌥⌘↓", "arrow.down", #selector(NoteTextView.moveLineDown(_:))),
            format("Duplicate Line", "⇧⌘D", "plus.square.on.square", #selector(NoteTextView.duplicateLine(_:))),
            item("Change Theme…", "⌥⌘T", "paintpalette") { [weak self] in self?.chooseTheme(nil) },
            item("Change Font…", "", "textformat") { [weak self] in self?.chooseFont(nil) },
            item("Bigger Text", "⌘+", "plus.magnifyingglass") { [weak self] in self?.zoomIn(nil) },
            item("Smaller Text", "⌘−", "minus.magnifyingglass") { [weak self] in self?.zoomOut(nil) },
            item("Show Notes Folder", "", "folder") { [weak self] in self?.revealFolder(nil) },
            item("Settings…", "⌘,", "gearshape") { [weak self] in self?.openSettings?() },
            item("Check for Updates…", "", "arrow.triangle.2.circlepath") { Updater.shared.check(userInitiated: true) },
            item("Quit Mini Notes", "⌘Q", "power") { NSApp.terminate(nil) },
        ]
    }

    // MARK: - Actions

    @objc func newNote(_ sender: Any?) {
        closePalette()
        if let id = currentID, store.note(id)?.isBlank == true {
            show()
            return
        }
        createNote()
    }

    @objc func duplicateNote(_ sender: Any?) {
        guard let id = currentID else { return }
        duplicate(id, open: true)
    }

    @objc func copyMarkdown(_ sender: Any?) {
        RichText.copy(markdown: textView.string)
        flash("Copied to clipboard")
    }

    @objc func exportNote(_ sender: Any?) {
        guard let id = currentID, let note = store.note(id) else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        save.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"
        save.beginSheetModal(for: panel) { response in
            guard response == .OK, let url = save.url else { return }
            try? note.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc func deleteNote(_ sender: Any?) {
        guard let id = currentID else { return }
        confirmDelete(id)
    }

    @objc func togglePinCurrent(_ sender: Any?) {
        guard let id = currentID, store.note(id)?.isBlank == false else { return }
        store.togglePin(id)
        flash(store.isPinned(id) ? "Pinned" : "Unpinned")
    }

    private func duplicate(_ id: String, open: Bool) {
        guard let note = store.note(id), !note.isBlank else { return }
        let copy = store.create(text: note.text)
        if open { self.open(copy.id); show() }
        flash("Duplicated")
    }

    private func confirmDelete(_ id: String) {
        guard let note = store.note(id) else { return }
        if note.isBlank {
            performDelete(id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.title)”?"
        alert.informativeText = "The note will be moved to the Trash."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { self?.performDelete(id) }
                if let p = self?.palette { p.refresh() }
            }
        }
    }

    private func performDelete(_ id: String) {
        cursorMemory[id] = nil
        guard id == currentID else {
            store.delete(id)
            flash("Moved to Trash")
            return
        }
        currentID = nil
        store.delete(id)
        if let next = store.byModified.first {
            open(next.id)
        } else {
            open(store.create().id)
        }
        flash("Moved to Trash")
    }

    @objc func previousNote(_ sender: Any?) { step(-1) }
    @objc func nextNote(_ sender: Any?) { step(1) }

    private func step(_ delta: Int) {
        let list = store.byCreated
        guard list.count > 1, let current = currentID, let i = list.firstIndex(where: { $0.id == current }) else { return }
        open(list[(i + delta + list.count) % list.count].id)
    }

    @objc func toggleFloat(_ sender: Any?) {
        Prefs.floatOnTop.toggle()
        applyFloat()
        flash(Prefs.floatOnTop ? "Floating on top" : "Floating off")
    }

    func applyFloat() {
        panel.level = Prefs.floatOnTop ? .floating : .normal
        pinButton?.setSymbol(Prefs.floatOnTop ? "pin.fill" : "pin", active: Prefs.floatOnTop)
    }

    @objc func hideWindow(_ sender: Any?) { hide() }

    @objc func zoomIn(_ sender: Any?) { setFontSize(Prefs.fontSize + 1) }
    @objc func zoomOut(_ sender: Any?) { setFontSize(Prefs.fontSize - 1) }
    @objc func resetZoom(_ sender: Any?) { setFontSize(15) }

    private func setFontSize(_ size: CGFloat) {
        let size = min(28, max(11, size))
        Prefs.fontSize = size
        styler.baseSize = size
        applyEditorSettings()
        flash("Text size \(Int(size))")
    }

    /// Re-applies font family, line spacing and line width (from Settings).
    func applyEditorSettings() {
        guard let ts = textView.textStorage else { return }
        styler.reloadFonts()
        layout.bodyFont = styler.body
        ts.beginEditing()
        styler.styleAll(ts)
        ts.endEditing()
        textView.typingAttributes = styler.baseAttributes
        textView.defaultParagraphStyle = styler.bodyPara
        textView.needsDisplay = true
        updateInsets()
    }

    @objc func revealFolder(_ sender: Any?) {
        NSWorkspace.shared.open(store.folder)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(togglePinCurrent(_:)) {
            item.title = store.isPinned(currentID ?? "") ? "Unpin Note" : "Pin Note"
        }
        if item.action == #selector(toggleFloat(_:)) { item.state = Prefs.floatOnTop ? .on : .off }
        return true
    }

    // MARK: - NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, sender.minSize.width), height: max(frameSize.height, sender.minSize.height))
    }

    func windowDidResize(_ notification: Notification) {
        // Safety net: never let a layout pass shrink the window below its minimum size.
        let min = panel.minSize
        if panel.frame.width < min.width || panel.frame.height < min.height {
            var f = panel.frame
            f.size.width = max(f.width, min.width)
            f.size.height = max(f.height, min.height)
            panel.setFrame(f, display: true)
            return
        }
        updateInsets()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    @objc private func scrolled() {
        header.setSeparatorVisible(scrollView.contentView.bounds.origin.y > 2)
    }
}
