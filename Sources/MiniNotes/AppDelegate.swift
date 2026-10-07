import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotesWindowController!
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?
    private var hotKeyOK = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        _ = ThemeManager.shared
        controller = NotesWindowController()
        controller.openSettings = { [weak self] in self?.openSettings(nil) }
        NSApp.mainMenu = buildMainMenu()
        setupStatusItem()

        HotKey.shared.handler = { [weak self] in self?.controller.toggle() }
        hotKeyOK = registerHotKey()

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if Prefs.hideOnDeactivate { self?.controller.hide(hideApp: false) }
            }
        }

        if !CommandLine.arguments.contains("--background") { controller.show() }
        if !hotKeyOK { openSettings(nil) }
        #if DEBUG
        debugSnapshotIfRequested()
        #endif
    }

    #if DEBUG
    /// Dev aid: MININOTES_SNAPSHOT=/path.png [MININOTES_ACTION=notes|actions|caret:<n>] renders the window to a PNG and quits.
    private func debugSnapshotIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MININOTES_SNAPSHOT"] else { return }
        if let appearance = env["MININOTES_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if let theme = env["MININOTES_THEME"] { ThemeManager.shared.select(theme, persist: false) }
        if ["selftest", "undotest", "themetest"].contains(env["MININOTES_ACTION"] ?? "") {
            // Tests edit text; never let them touch a real notes folder.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mininotes-test-\(UUID().uuidString)")
            NotesStore.shared.setFolder(tmp, remember: false)
            controller.reloadFolder()
        }
        if env["MININOTES_ACTION"] == "selftest" { runSelfTest(); NSApp.terminate(nil); return }
        if env["MININOTES_ACTION"] == "undotest" { runUndoTest(); return }
        if env["MININOTES_ACTION"] == "themetest" { runThemeTest(); NSApp.terminate(nil); return }
        if let dest = env["MININOTES_SYNCTEST"] { runSyncTest(URL(fileURLWithPath: dest)); return }
        switch env["MININOTES_ACTION"] ?? "" {
        case "notes": controller.browseNotes(nil)
        case "settings": openSettings(nil)
        case "theme": controller.chooseTheme(nil)
        case "actions": controller.showActions(nil)
        case let a where a.hasPrefix("caret:"):
            controller.textView.setSelectedRange(NSRange(location: Int(a.dropFirst(6)) ?? 0, length: 0)); controller.textView.scrollRangeToVisible(controller.textView.selectedRange())
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            let target = env["MININOTES_ACTION"] == "settings" ? self?.settings?.window : self?.controller.panel
            guard let self, let view = target?.contentView else { return }
            if env["MININOTES_DUMP"] != nil {
                let tv = self.controller.textView
                let lm = tv.layoutManager!, ts = tv.textStorage!
                print("tv.frame", tv.frame, "inset", tv.textContainerInset, "container", tv.textContainer!.size,
                      "clip", tv.enclosingScrollView!.contentSize)
                lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, used, _, g, _ in
                    let c = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
                    let s = (ts.string as NSString).substring(with: c).replacingOccurrences(of: "\n", with: "⏎")
                    print(String(format: "y=%6.1f h=%5.1f used=%5.1f", rect.minY, rect.height, used.height), c, s)
                }
            }
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
                NSGraphicsContext.restoreGraphicsState()
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Migrates notes into `dest`, then simulates another device editing files there.
    private func runSyncTest(_ dest: URL) {
        let store = NotesStore.shared
        let fm = FileManager.default
        // Seed a throwaway source folder so the migration never touches real notes.
        let source = fm.temporaryDirectory.appendingPathComponent("mininotes-sync-src-\(UUID().uuidString)")
        try! fm.createDirectory(at: source, withIntermediateDirectories: true)
        try! "# First note\nhello".write(to: source.appendingPathComponent("seed-1.md"), atomically: false, encoding: .utf8)
        try! "# Second note".write(to: source.appendingPathComponent("seed-2.md"), atomically: false, encoding: .utf8)
        store.setFolder(source, remember: false)
        controller.reloadFolder()
        var failures = 0
        func check(_ name: String, _ ok: Bool) { if !ok { failures += 1 }; print(ok ? "PASS" : "FAIL", name) }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

        let before = store.notes.values.filter { !$0.isBlank }
        let created = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.created) })
        try! store.migrate(to: dest, removeSources: true)
        controller.reloadFolder()
        let moved = before.allSatisfy { fm.fileExists(atPath: dest.appendingPathComponent($0.id + ".md").path) }
        check("migrate copies all notes", moved && store.notes.count >= before.count)
        check("migrate removes sources", before.allSatisfy { !fm.fileExists(atPath: source.appendingPathComponent($0.id + ".md").path) })
        check("migrate keeps creation dates", before.allSatisfy { n in
            let d = (try? dest.appendingPathComponent(n.id + ".md").resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return d.map { abs($0.timeIntervalSince(created[n.id]!)) < 1 } ?? false
        })

        let current = controller.currentID!
        // Another device adds a note.
        try! "# From my other Mac\n".write(to: dest.appendingPathComponent("remote-1.md"), atomically: true, encoding: .utf8)
        after(0.8) {
            check("new remote note appears", store.note("remote-1")?.title == "From my other Mac")
            // Another device edits the open note (iCloud replaces files atomically).
            try! "# Edited remotely\nhello".write(to: dest.appendingPathComponent(current + ".md"), atomically: true, encoding: .utf8)
            after(0.8) {
                check("open note reloads live", self.controller.textView.string == "# Edited remotely\nhello")
                // Local edit, then a remote edit while unsaved: local must win.
                self.controller.textView.insertText(" local", replacementRange: NSRange(location: (self.controller.textView.string as NSString).length, length: 0))
                try! "remote clobber".write(to: dest.appendingPathComponent(current + ".md"), atomically: true, encoding: .utf8)
                after(0.3) {
                    check("unsaved local edit not clobbered", self.controller.textView.string.hasSuffix("hello local"))
                    // Another device deletes a note.
                    try! fm.removeItem(at: dest.appendingPathComponent("remote-1.md"))
                    after(0.8) {
                        check("remote delete removes note", store.note("remote-1") == nil)
                        store.flush()
                        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// Types "[] a" one key per run-loop pass (like real keystrokes), then undoes step by step.
    private func runUndoTest() {
        setvbuf(stdout, nil, _IONBF, 0)
        let tv = controller.textView
        tv.string = ""
        var steps: [() -> Void] = "[] a".map { c in { tv.insertText(String(c), replacementRange: tv.selectedRange()) } }
        var log: [String] = []
        steps.append { log.append(tv.string) }
        for _ in 0..<4 { steps.append { tv.undoManager?.undo(); log.append(tv.string) } }
        func run(_ i: Int) {
            guard i < steps.count else {
                print("typed:", log[0].debugDescription, "then undo →", log.dropFirst().map(\.debugDescription).joined(separator: " → "))
                NSApp.terminate(nil)
                return
            }
            steps[i]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { run(i + 1) }
        }
        run(0)
    }

    private func runThemeTest() {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ name: String, _ ok: Bool) { if !ok { failures += 1 }; print(ok ? "PASS" : "FAIL", name) }
        func key(_ sel: Selector) {
            guard let p = controller.debugPalette else { return }
            _ = p.control(p.field, textView: NSTextView(), doCommandBy: sel)
        }
        ThemeManager.shared.select(Themes.system)
        check("starts on System", Theme.spec == nil && Prefs.themeID == "system")

        controller.chooseTheme(nil)
        check("picker opens", controller.debugPalette?.kind == "themes")
        key(#selector(NSResponder.moveDown(_:)))
        check("arrow previews next theme", Theme.spec?.id == "vscode-dark" || Theme.spec?.id == "vscode-light")
        check("preview is not saved", Prefs.themeID == "system")
        key(#selector(NSResponder.cancelOperation(_:)))
        check("Esc reverts to System", Theme.spec == nil && ThemeManager.shared.selectedID == "system")
        check("Esc closes picker", controller.debugPalette == nil)

        controller.chooseTheme(nil)
        key(#selector(NSResponder.moveDown(_:)))
        key(#selector(NSResponder.moveDown(_:)))
        key(#selector(NSResponder.insertNewline(_:)))
        check("Enter saves theme", Prefs.themeID == "github" && ThemeManager.shared.selectedID == "github")
        check("Enter closes picker", controller.debugPalette == nil)

        controller.chooseTheme(nil)
        key(#selector(NSResponder.moveDown(_:)))
        controller.hide()
        check("hiding window mid-preview reverts", ThemeManager.shared.selectedID == "github" && Prefs.themeID == "github")

        ThemeManager.shared.select(Themes.system)
        controller.textView.string = "Hello"
        ThemeManager.shared.select("github-dark")
        let styled = controller.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let expected = NSColor(hex: 0xE6EDF3)
        check("text restyled with theme color", styled?.usingColorSpace(.sRGB) == expected.usingColorSpace(.sRGB))
        check("dark theme sets dark appearance", controller.panel.appearance?.name == .darkAqua)
        ThemeManager.shared.select("solarized-light")
        check("light theme sets light appearance", controller.panel.appearance?.name == .aqua)
        ThemeManager.shared.select(Themes.system)
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }

    private func runSelfTest() {
        setvbuf(stdout, nil, _IONBF, 0)
        let tv = controller.textView
        var failures = 0
        func check(_ name: String, _ start: String, caret: Int? = nil, sel: NSRange? = nil,
                   _ action: (NoteTextView) -> Void, expect: String) {
            tv.string = start
            tv.setSelectedRange(sel ?? NSRange(location: caret ?? (start as NSString).length, length: 0))
            action(tv)
            let ok = tv.string == expect
            if !ok { failures += 1 }
            print(ok ? "PASS" : "FAIL", name, ok ? "" : "→ got \(tv.string.debugDescription), want \(expect.debugDescription)")
        }
        check("bullet continues", "- one", { $0.insertNewline(nil) }, expect: "- one\n- ")
        check("task continues unchecked", "- [x] done", { $0.insertNewline(nil) }, expect: "- [x] done\n- [ ] ")
        check("ordered increments", "1. a", { $0.insertNewline(nil) }, expect: "1. a\n2. ")
        check("quote continues", "> hi", { $0.insertNewline(nil) }, expect: "> hi\n> ")
        check("empty item ends list", "- a\n- ", { $0.insertNewline(nil) }, expect: "- a\n")
        check("empty nested item outdents", "- a\n  - ", { $0.insertNewline(nil) }, expect: "- a\n- ")
        check("indent carries", "    code", { $0.insertNewline(nil) }, expect: "    code\n    ")
        check("backspace removes marker", "- ", { $0.deleteBackward(nil) }, expect: "")
        check("backspace removes heading", "## ", { $0.deleteBackward(nil) }, expect: "")
        check("tab indents list", "- a", { $0.insertTab(nil) }, expect: "  - a")
        check("shift-tab outdents", "  - a", { $0.insertBacktab(nil) }, expect: "- a")
        check("bold wraps selection", "hello world", sel: NSRange(location: 6, length: 5), { $0.formatBold(nil) }, expect: "hello **world**")
        check("bold unwraps", "hello **world**", sel: NSRange(location: 8, length: 5), { $0.formatBold(nil) }, expect: "hello world")
        check("italic wraps word at caret", "hello world", caret: 2, { $0.formatItalic(nil) }, expect: "_hello_ world")
        check("code empty inserts pair", "x ", { $0.formatInlineCode(nil) }, expect: "x ``")
        check("h1 toggles on", "Title", { $0.formatHeading1(nil) }, expect: "# Title")
        check("h2 replaces h1", "# Title", { $0.formatHeading2(nil) }, expect: "## Title")
        check("h2 toggles off", "## Title", { $0.formatHeading2(nil) }, expect: "Title")
        check("checklist multi-line", "a\nb", sel: NSRange(location: 0, length: 3), { $0.formatChecklist(nil) }, expect: "- [ ] a\n- [ ] b")
        check("numbered multi-line", "a\nb", sel: NSRange(location: 0, length: 3), { $0.formatNumberedList(nil) }, expect: "1. a\n2. b")
        check("bullet → task", "- a", { $0.formatChecklist(nil) }, expect: "- [ ] a")
        check("toggle task checks", "- [ ] a", { $0.toggleTask(nil) }, expect: "- [x] a")
        check("toggle task unchecks", "- [x] a", { $0.toggleTask(nil) }, expect: "- [ ] a")
        func type(_ s: String) -> (NoteTextView) -> Void {
            { tv in s.forEach { tv.insertText(String($0), replacementRange: tv.selectedRange()) } }
        }
        check("typing [] makes task", "", type("[] buy milk"), expect: "- [ ] buy milk")
        check("typing [ ] makes task", "", type("[ ] x"), expect: "- [ ] x")
        check("typing [x] makes checked task", "", type("[x] done"), expect: "- [x] done")
        check("indented [] keeps indent", "- a\n", type("  [] b"), expect: "- a\n  - [ ] b")
        check("- [] completes task", "", type("- [] y"), expect: "- [ ] y")
        check("[] mid-line untouched", "", type("see [] here"), expect: "see [] here")
        check("task then Enter continues", "", { tv in type("[] a")(tv); tv.insertNewline(nil) }, expect: "- [ ] a\n- [ ] ")
        check("code block wraps line", "let x = 1", { $0.formatCodeBlock(nil) }, expect: "```\nlet x = 1\n```")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }
    #endif

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotesStore.shared.flush()
    }

    private func registerHotKey() -> Bool {
        HotKey.shared.register(keyCode: Prefs.hotKeyCode, modifiers: Prefs.hotKeyMods)
    }

    @objc func openSettings(_ sender: Any?) {
        if settings == nil {
            settings = SettingsWindowController(
                registerHotKey: { [weak self] in self?.registerHotKey() ?? false },
                floatChanged: { [weak self] in self?.controller.applyFloat() },
                folderChanged: { [weak self] in self?.controller.reloadFolder() }
            )
        }
        settings?.refreshStatus(hotKeyOK)
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Mini Notes")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Mini Notes", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Note", action: #selector(newFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mini Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    @objc private func openFromMenu() { controller.show() }
    @objc private func newFromMenu() { controller.newNote(nil) }

    // MARK: - Main menu (invisible for an agent app, but drives all key equivalents)

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let c: AnyObject = controller

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String,
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            return i
        }
        let sep = { NSMenuItem.separator() }
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)
        let enter = "\r"

        submenu("Mini Notes", [
            item("Settings…", #selector(openSettings(_:)), ",", target: self),
            sep(),
            item("Hide Window", #selector(NotesWindowController.hideWindow(_:)), "w", target: c),
            item("Quit Mini Notes", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Note", [
            item("New Note", #selector(NotesWindowController.newNote(_:)), "n", target: c),
            item("Browse Notes", #selector(NotesWindowController.browseNotes(_:)), "p", target: c),
            item("Actions", #selector(NotesWindowController.showActions(_:)), "k", target: c),
            sep(),
            item("Previous Note", #selector(NotesWindowController.previousNote(_:)), "[", target: c),
            item("Next Note", #selector(NotesWindowController.nextNote(_:)), "]", target: c),
            sep(),
            item("Duplicate Note", #selector(NotesWindowController.duplicateNote(_:)), "d", target: c),
            item("Copy Note as Markdown", #selector(NotesWindowController.copyMarkdown(_:)), "c", [.command, .shift], target: c),
            item("Export Note…", #selector(NotesWindowController.exportNote(_:)), "e", [.command, .shift], target: c),
            item("Delete Note", #selector(NotesWindowController.deleteNote(_:)), backspace, [.command, .shift], target: c),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            sep(),
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)),
            item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue)),
            item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: Int(NSFindPanelAction.previous.rawValue)),
        ])
        submenu("Format", [
            item("Heading 1", #selector(NoteTextView.formatHeading1(_:)), "1", [.command, .option]),
            item("Heading 2", #selector(NoteTextView.formatHeading2(_:)), "2", [.command, .option]),
            item("Heading 3", #selector(NoteTextView.formatHeading3(_:)), "3", [.command, .option]),
            sep(),
            item("Bold", #selector(NoteTextView.formatBold(_:)), "b"),
            item("Italic", #selector(NoteTextView.formatItalic(_:)), "i"),
            item("Strikethrough", #selector(NoteTextView.formatStrikethrough(_:)), "x", [.command, .shift]),
            item("Highlight", #selector(NoteTextView.formatHighlight(_:)), "h", [.command, .shift]),
            item("Inline Code", #selector(NoteTextView.formatInlineCode(_:)), "e"),
            item("Link", #selector(NoteTextView.formatLink(_:)), "l"),
            sep(),
            item("Bulleted List", #selector(NoteTextView.formatBulletList(_:)), "8", [.command, .shift]),
            item("Numbered List", #selector(NoteTextView.formatNumberedList(_:)), "7", [.command, .shift]),
            item("Checklist", #selector(NoteTextView.formatChecklist(_:)), "9", [.command, .shift]),
            item("Toggle Checkbox", #selector(NoteTextView.toggleTask(_:)), enter),
            item("Blockquote", #selector(NoteTextView.formatQuote(_:)), "b", [.command, .shift]),
            item("Code Block", #selector(NoteTextView.formatCodeBlock(_:)), "c", [.command, .option]),
        ])
        submenu("View", [
            item("Theme…", #selector(NotesWindowController.chooseTheme(_:)), "t", [.command, .option], target: c),
            item("Float on Top", #selector(NotesWindowController.toggleFloat(_:)), "f", [.command, .shift], target: c),
            sep(),
            item("Bigger Text", #selector(NotesWindowController.zoomIn(_:)), "=", target: c),
            item("Smaller Text", #selector(NotesWindowController.zoomOut(_:)), "-", target: c),
            item("Actual Size", #selector(NotesWindowController.resetZoom(_:)), "0", target: c),
        ])
        return main
    }
}
