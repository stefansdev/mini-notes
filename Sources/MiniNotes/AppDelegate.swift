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
        #if DEBUG
        let skipHotKey = ProcessInfo.processInfo.environment["MININOTES_NO_HOTKEY"] != nil
        #else
        let skipHotKey = false
        #endif
        hotKeyOK = skipHotKey || registerHotKey()

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if Prefs.hideOnDeactivate { self?.controller.hide(hideApp: false) }
            }
        }

        Updater.shared.onStatus = { [weak self] text in self?.controller.showStatus(text) }
        Updater.shared.start()
        NotificationCenter.default.addObserver(forName: .updateAvailable, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAvailableChanged() }
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
        if env["MININOTES_ACTION"] == "updatetest" {
            setvbuf(stdout, nil, _IONBF, 0)
            Task {
                do {
                    let r = try await Updater.shared.fetchLatest()
                    print("installed:", Updater.shared.currentVersion, "latest:", r.version,
                          "newer:", Updater.isNewer(r.version, than: Updater.shared.currentVersion))
                    try await Updater.shared.performInstall(r)
                    let v = Bundle(url: Bundle.main.bundleURL)?.infoDictionary?["CFBundleShortVersionString"] as? String
                    let onDisk = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"]
                    print("UPDATE OK, bundle on disk is now", onDisk ?? v ?? "?")
                } catch {
                    print("UPDATE FAILED:", error.localizedDescription)
                }
                NSApp.terminate(nil)
            }
            return
        }
        if env["MININOTES_ACTION"] == "themetest" { runThemeTest(); NSApp.terminate(nil); return }
        if let dest = env["MININOTES_SYNCTEST"] { runSyncTest(URL(fileURLWithPath: dest)); return }
        switch env["MININOTES_ACTION"] ?? "" {
        case "notes": controller.browseNotes(nil)
        case "settings": openSettings(nil)
        case "theme": controller.chooseTheme(nil)
        case let a where a.hasPrefix("fold:"):
            // e.g. MININOTES_ACTION="fold:## Todo" folds that heading
            let ns = controller.textView.string as NSString
            let r = ns.range(of: String(a.dropFirst(5)))
            if r.location != NSNotFound, let lm = controller.textView.layoutManager as? MarkdownLayoutManager {
                print("fold", a, "at", r.location, "→", lm.toggleFold(at: r.location), lm.folds)
                controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
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
            tv.didChangeText()   // style now, like the app does when it loads text
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
            { tv in s.forEach { tv.insertText(String($0), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
        }
        check("typing [] makes task", "", type("[] buy milk"), expect: "- [ ] buy milk")
        check("typing [ ] makes task", "", type("[ ] x"), expect: "- [ ] x")
        check("typing [x] makes checked task", "", type("[x] done"), expect: "- [x] done")
        check("indented [] keeps indent", "- a\n", type("  [] b"), expect: "- a\n  - [ ] b")
        check("- [] completes task", "", type("- [] y"), expect: "- [ ] y")
        check("[] mid-line untouched", "", type("see [] here"), expect: "see [] here")
        check("task then Enter continues", "", { tv in type("[] a")(tv); tv.insertNewline(nil) }, expect: "- [ ] a\n- [ ] ")
        // Caret + styling (regression: caret used to jump to the end of the line when typing mid-line)
        check("typing mid-line keeps caret", "hello world", caret: 5, { tv in type("XY")(tv) }, expect: "helloXY world")
        check("…caret is after typed text", "hello world", caret: 5, { tv in type("XY")(tv); if tv.selectedRange().location != 7 { tv.string = "caret at \(tv.selectedRange().location)" } }, expect: "helloXY world")
        check("typed heading gets styled", "", { tv in
            type("# Hi")(tv)
            let size = (tv.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            if size <= Prefs.fontSize { tv.string = "not styled (\(size))" }
        }, expect: "# Hi")

        // Auto-pairs
        check("( pairs", "", type("("), expect: "()")
        check("typing ) steps over", "", type("(a)"), expect: "(a)")
        check("backspace deletes empty pair", "", { tv in type("(")(tv); tv.deleteBackward(nil) }, expect: "")
        check("selection wraps with *", "hi", sel: NSRange(location: 0, length: 2), type("*"), expect: "*hi*")
        check("selection wraps with (", "hi", sel: NSRange(location: 0, length: 2), type("("), expect: "(hi)")
        check("** pairs to ****", "", type("**"), expect: "****")
        check("bold typed through pairs", "", type("**b**"), expect: "**b**")
        check("apostrophe after letter not paired", "", type("don't"), expect: "don't")
        check("``` makes a fence", "", type("```"), expect: "```")
        check("inline code pairs and steps over", "", type("`x`"), expect: "`x`")
        check("no pair before a word", "word", caret: 0, type("("), expect: "(word")

        // Line commands
        check("move line up", "a\nb\nc", caret: 4, { $0.moveLineUp(nil) }, expect: "a\nc\nb")
        check("move line down", "a\nb\nc", caret: 0, { $0.moveLineDown(nil) }, expect: "b\na\nc")
        check("move last line up", "a\nb", caret: 3, { $0.moveLineUp(nil) }, expect: "b\na")
        check("duplicate line", "a\nb", caret: 0, { $0.duplicateLine(nil) }, expect: "a\na\nb")
        check("duplicate last line", "a\nb", caret: 3, { $0.duplicateLine(nil) }, expect: "a\nb\nb")

        // Paste link over selection
        let pb = NSPasteboard.general
        let savedClipboard = pb.string(forType: .string)
        pb.clearContents(); pb.setString("https://example.com", forType: .string)
        check("paste URL over selection makes link", "see docs", sel: NSRange(location: 4, length: 4), { $0.paste(nil) }, expect: "see [docs](https://example.com)")
        check("paste URL without selection pastes text", "x ", { $0.paste(nil) }, expect: "x https://example.com")
        pb.clearContents(); pb.setString("not a url", forType: .string)
        check("paste text over selection replaces", "see docs", sel: NSRange(location: 4, length: 4), { $0.paste(nil) }, expect: "see not a url")
        pb.clearContents(); if let savedClipboard { pb.setString(savedClipboard, forType: .string) }

        // Rich text
        let html = RichText.html("# T\n**b** and `**c**` [l](https://x.y)\n- [x] done\n  - sub")
        let rich = html.contains("<h1>T</h1>") && html.contains("<strong>b</strong>") && html.contains("<code>**c**</code>")
            && html.contains(#"<a href="https://x.y">l</a>"#) && html.contains("☑ done") && html.contains("<ul><li>sub")
        check("markdown → HTML", "", { tv in if !rich { tv.string = html } }, expect: "")

        // Code highlighting
        ThemeManager.shared.select("github-dark", persist: false)   // concrete colors compare by value
        func rgb(_ c: NSColor?) -> String { c?.usingColorSpace(.sRGB).map { String(format: "%.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) } ?? "nil" }
        func color(_ tv: NSTextView, _ i: Int) -> String { rgb(tv.textStorage!.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor) }
        func token(_ k: TokenKind) -> String { rgb(Theme.token(k)) }
        check("swift keyword highlighted", "```swift\nlet x = \"s\" // c\n```", { tv in
            let ok = color(tv, 9) == token(.keyword) && color(tv, 17) == token(.string) && color(tv, 21) == token(.comment)
            if !ok { tv.string = "colors wrong" }
        }, expect: "```swift\nlet x = \"s\" // c\n```")
        check("opening /* restyles rest of block", "```js\nlet a = 1\nlet b = 2\n```", { tv in
            tv.setSelectedRange(NSRange(location: 6, length: 0))
            tv.insertText("/*", replacementRange: NSRange(location: NSNotFound, length: 0))
            // "let b" on the next line is now inside the comment
            let i = (tv.string as NSString).range(of: "let b").location
            if color(tv, i) != token(.comment) { tv.string = "not commented" }
        }, expect: "```js\n/*let a = 1\nlet b = 2\n```")
        ThemeManager.shared.select(Themes.system, persist: false)
        // Folding
        if let lm = tv.layoutManager as? MarkdownLayoutManager {
            check("fold hides section only", "# A\ntext\n# B\nmore", caret: 0, { tv in
                lm.toggleFold(at: 0)
                let b = (tv.string as NSString).range(of: "# B").location
                if lm.folds[0] == nil || !lm.isFolded(4) || lm.isFolded(b) { tv.string = "bad fold \(lm.folds)" }
                lm.unfoldAll()
            }, expect: "# A\ntext\n# B\nmore")
            check("lower headings fold inside", "# A\n## a1\nx\n# B", caret: 0, { tv in
                lm.toggleFold(at: 0)
                if !lm.isFolded(4) { tv.string = "## a1 not folded" }
                lm.unfoldAll()
            }, expect: "# A\n## a1\nx\n# B")
            check("caret into folded text unfolds", "# A\ntext\n# B", caret: 0, { tv in
                lm.toggleFold(at: 0)
                tv.setSelectedRange(NSRange(location: 6, length: 0))
                if !lm.folds.isEmpty { tv.string = "still folded" }
            }, expect: "# A\ntext\n# B")
            check("edit above keeps fold", "x\n# A\ntext\n# B", caret: 0, { tv in
                lm.toggleFold(at: 2)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.insertText("yy", replacementRange: NSRange(location: NSNotFound, length: 0))
                if lm.folds[4] == nil { tv.string = "fold lost \(lm.folds)" }
                lm.unfoldAll()
            }, expect: "yyx\n# A\ntext\n# B")
            check("editing the heading unfolds", "# A\ntext\n# B", caret: 0, { tv in
                lm.toggleFold(at: 0)
                tv.setSelectedRange(NSRange(location: 3, length: 0))
                tv.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
                if !lm.folds.isEmpty { tv.string = "still folded" }
            }, expect: "# AZ\ntext\n# B")
            check("blank sections don't fold", "# A\n\n# B", caret: 0, { tv in
                if lm.toggleFold(at: 0) { tv.string = "folded blank" }
            }, expect: "# A\n\n# B")
        }

        // Pins persist in the notes folder
        let pinNote = NotesStore.shared.create(text: "pin me")
        NotesStore.shared.flush()
        NotesStore.shared.togglePin(pinNote.id)
        NotesStore.shared.load()
        check("pin persists on disk", "", { tv in if !NotesStore.shared.isPinned(pinNote.id) { tv.string = "lost pin" } }, expect: "")

        // Font family
        let savedFamily = Prefs.fontFamily
        Prefs.fontFamily = "mono"
        NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil)
        check("monospace font setting", "abc", { tv in
            tv.didChangeText()
            let f = tv.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            if f?.isFixedPitch != true { tv.string = "not mono: \(f?.fontName ?? "nil")" }
        }, expect: "abc")
        Prefs.fontFamily = savedFamily
        NotificationCenter.default.post(name: .editorSettingsDidChange, object: nil)

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

    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.check(userInitiated: true) }
    @objc func installUpdate(_ sender: Any?) { Updater.shared.promptInstall() }

    private func updateAvailableChanged() {
        guard let menu = statusItem.menu else { return }
        menu.items.filter { $0.action == #selector(installUpdate(_:)) }.forEach { menu.removeItem($0) }
        if let release = Updater.shared.available {
            let item = NSMenuItem(title: "Install Update \(release.version)…", action: #selector(installUpdate(_:)), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            controller.showStatus("Update \(release.version) available — ⌘K → Install Update")
        }
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
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
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
            item("Check for Updates…", #selector(checkForUpdates(_:)), "", target: self),
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
            item("Pin Note", #selector(NotesWindowController.togglePinCurrent(_:)), "p", [.command, .shift], target: c),
            item("Copy Note", #selector(NotesWindowController.copyMarkdown(_:)), "c", [.command, .shift], target: c),
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
            item("Move Line Up", #selector(NoteTextView.moveLineUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Move Line Down", #selector(NoteTextView.moveLineDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item("Duplicate Line", #selector(NoteTextView.duplicateLine(_:)), "d", [.command, .shift]),
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
            item("Toggle Fold", #selector(NoteTextView.toggleFoldAtCaret(_:)), "f", [.command, .option]),
            item("Unfold All", #selector(NoteTextView.unfoldAllSections(_:)), "f", [.command, .option, .shift]),
            item("Float on Top", #selector(NotesWindowController.toggleFloat(_:)), "f", [.command, .shift], target: c),
            sep(),
            item("Bigger Text", #selector(NotesWindowController.zoomIn(_:)), "=", target: c),
            item("Smaller Text", #selector(NotesWindowController.zoomOut(_:)), "-", target: c),
            item("Actual Size", #selector(NotesWindowController.resetZoom(_:)), "0", target: c),
        ])
        return main
    }
}
