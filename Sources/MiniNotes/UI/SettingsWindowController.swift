import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Click, then press a key combination. Esc cancels.
final class ShortcutRecorder: NSButton {
    var onChange: ((UInt32, UInt32, String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?
    private var display: String

    init(display: String) {
        self.display = display
        super.init(frame: .zero)
        bezelStyle = .rounded
        title = display.isEmpty ? "Record Shortcut" : display
        target = self
        action = #selector(start)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func start() {
        guard monitor == nil else { return }
        title = "Type shortcut…"
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isFunctionKey = HotKey.functionKeys[Int(event.keyCode)] != nil
            guard !mods.subtracting(.shift).isEmpty || isFunctionKey else {
                NSSound.beep()
                return nil
            }
            let display = HotKey.modifierSymbols(mods) + HotKey.keyName(event)
            self.display = display
            self.onChange?(UInt32(event.keyCode), HotKey.carbonModifiers(mods), display)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = display
        onRecordingChange?(false)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let recorder = ShortcutRecorder(display: Prefs.hotKeyDisplay)
    private let status = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private let iCloud = NSButton(checkboxWithTitle: "Sync notes with iCloud Drive", target: nil, action: nil)
    private let iCloudHint = NSTextField(labelWithString: "")
    private let themePopup = NSPopUpButton()
    private let registerHotKey: () -> Bool
    private let floatChanged: () -> Void
    private let folderChanged: () -> Void

    init(registerHotKey: @escaping () -> Bool, floatChanged: @escaping () -> Void, folderChanged: @escaping () -> Void) {
        self.registerHotKey = registerHotKey
        self.floatChanged = floatChanged
        self.folderChanged = folderChanged
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mini Notes Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        recorder.onRecordingChange = { [weak self] recording in
            MainActor.assumeIsolated {
                if recording {
                    HotKey.shared.unregister()
                } else {
                    self?.refreshStatus(self?.registerHotKey() ?? false)
                }
            }
        }
        recorder.onChange = { code, mods, display in
            Prefs.hotKeyCode = code
            Prefs.hotKeyMods = mods
            Prefs.hotKeyDisplay = display
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .systemRed

        let float = NSButton(checkboxWithTitle: "Keep the notes window above other apps", target: self, action: #selector(toggleFloat(_:)))
        float.state = Prefs.floatOnTop ? .on : .off
        let hide = NSButton(checkboxWithTitle: "Hide when switching to another app", target: self, action: #selector(toggleHide(_:)))
        hide.state = Prefs.hideOnDeactivate ? .on : .off
        let login = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        iCloud.target = self
        iCloud.action = #selector(toggleICloud(_:))
        iCloud.isEnabled = NotesStore.iCloudAvailable
        if !NotesStore.iCloudAvailable { iCloud.toolTip = "iCloud Drive is not enabled on this Mac." }
        iCloudHint.font = .systemFont(ofSize: 11)
        iCloudHint.textColor = .secondaryLabelColor

        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshFolder()

        let change = NSButton(title: "Change…", target: self, action: #selector(changeFolder))
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealFolder))

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        func row(_ views: NSView...) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .horizontal
            s.spacing = 8
            return s
        }

        buildThemeMenu()
        NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectCurrentTheme() }
        }

        let grid = NSGridView(views: [
            [label("Toggle window:"), row(recorder, status)],
            [label("Theme:"), themePopup],
            [NSGridCell.emptyContentView, float],
            [NSGridCell.emptyContentView, hide],
            [NSGridCell.emptyContentView, login],
            [label("Sync:"), iCloud],
            [NSGridCell.emptyContentView, iCloudHint],
            [label("Notes folder:"), folderLabel],
            [NSGridCell.emptyContentView, row(change, reveal)],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 10
        grid.rowSpacing = 12
        grid.row(at: 5).topPadding = 8
        grid.row(at: 6).topPadding = -6
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
        ])
        window?.contentView = content
        window?.setContentSize(content.fittingSize)
    }

    private func buildThemeMenu() {
        let menu = NSMenu()
        func add(_ id: String) {
            let item = NSMenuItem(title: Themes.name(id), action: nil, keyEquivalent: "")
            item.representedObject = id
            item.image = Themes.swatch(id)
            menu.addItem(item)
        }
        func header(_ title: String) {
            menu.addItem(.separator())
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        add(Themes.system)
        header("Follow macOS light / dark")
        Themes.families.forEach { add($0.id) }
        header("Dark")
        Themes.all.filter(\.dark).forEach { add($0.id) }
        header("Light")
        Themes.all.filter { !$0.dark }.forEach { add($0.id) }
        themePopup.menu = menu
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        selectCurrentTheme()
    }

    private func selectCurrentTheme() {
        let id = ThemeManager.shared.selectedID
        if let item = themePopup.itemArray.first(where: { $0.representedObject as? String == id }) {
            themePopup.select(item)
        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        ThemeManager.shared.select(id)
    }

    func refreshStatus(_ ok: Bool) {
        status.stringValue = ok ? "" : "Shortcut is taken by another app"
    }

    private func refreshFolder() {
        let store = NotesStore.shared
        folderLabel.stringValue = store.isInICloud ? "iCloud Drive › Mini Notes"
            : (store.folder.path as NSString).abbreviatingWithTildeInPath
        iCloud.state = store.isInICloud ? .on : .off
        iCloudHint.stringValue = store.isInICloud ? "Notes sync across every Mac signed in to your Apple Account."
            : "Moves your notes into iCloud Drive so they sync across your Macs."
    }

    @objc private func toggleICloud(_ sender: NSButton) {
        let store = NotesStore.shared
        do {
            if sender.state == .on {
                try store.migrate(to: NotesStore.iCloudFolder, removeSources: true)
            } else {
                // Leave the iCloud copies in place; just stop using them.
                try store.migrate(to: Prefs.defaultNotesFolder, removeSources: false)
            }
            folderChanged()
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
        refreshFolder()
    }

    @objc private func toggleFloat(_ sender: NSButton) {
        Prefs.floatOnTop = sender.state == .on
        floatChanged()
    }

    @objc private func toggleHide(_ sender: NSButton) {
        Prefs.hideOnDeactivate = sender.state == .on
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).beginSheetModal(for: window!)
        }
    }

    @objc private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder for your notes. Existing .md files in it will show up as notes."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                NotesStore.shared.setFolder(url)
                self?.refreshFolder()
                self?.folderChanged()
            }
        }
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.open(NotesStore.shared.folder)
    }

    func windowWillClose(_ notification: Notification) {
        recorder.stop()
    }
}
