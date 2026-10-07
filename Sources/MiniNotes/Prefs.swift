import AppKit
import Carbon.HIToolbox

enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "hotKeyCode": kVK_ANSI_N,
            "hotKeyMods": cmdKey | optionKey,
            "hotKeyDisplay": "⌥⌘N",
            "floatOnTop": true,
            "hideOnDeactivate": false,
            "fontSize": 15.0,
        ])
    }

    static var hotKeyCode: UInt32 {
        get { UInt32(d.integer(forKey: "hotKeyCode")) }
        set { d.set(Int(newValue), forKey: "hotKeyCode") }
    }

    static var hotKeyMods: UInt32 {
        get { UInt32(d.integer(forKey: "hotKeyMods")) }
        set { d.set(Int(newValue), forKey: "hotKeyMods") }
    }

    static var hotKeyDisplay: String {
        get { d.string(forKey: "hotKeyDisplay") ?? "" }
        set { d.set(newValue, forKey: "hotKeyDisplay") }
    }

    static var floatOnTop: Bool {
        get { d.bool(forKey: "floatOnTop") }
        set { d.set(newValue, forKey: "floatOnTop") }
    }

    static var hideOnDeactivate: Bool {
        get { d.bool(forKey: "hideOnDeactivate") }
        set { d.set(newValue, forKey: "hideOnDeactivate") }
    }

    static var fontSize: CGFloat {
        get { CGFloat(d.double(forKey: "fontSize")) }
        set { d.set(Double(newValue), forKey: "fontSize") }
    }

    static var lastNoteID: String? {
        get { d.string(forKey: "lastNoteID") }
        set { d.set(newValue, forKey: "lastNoteID") }
    }

    static var notesFolder: URL {
        get {
            if let path = d.string(forKey: "notesFolder") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return defaultNotesFolder
        }
        set { d.set(newValue.path, forKey: "notesFolder") }
    }

    static var defaultNotesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mini Notes/Notes", isDirectory: true)
    }
}

extension Prefs {
    static var themeID: String {
        get { UserDefaults.standard.string(forKey: "themeID") ?? Themes.system }
        set { UserDefaults.standard.set(newValue, forKey: "themeID") }
    }
}

extension Prefs {
    /// Auto-close brackets, quotes, backticks and **.
    static var autoPair: Bool {
        get { UserDefaults.standard.object(forKey: "autoPair") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPair") }
    }

    /// "system", "rounded", "serif", "mono", or a font family name.
    static var fontFamily: String {
        get { UserDefaults.standard.string(forKey: "fontFamily") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "fontFamily") }
    }

    /// Max text column width in points; 0 = full window width.
    static var lineWidth: CGFloat {
        get { UserDefaults.standard.object(forKey: "lineWidth") as? CGFloat ?? 720 }
        set { UserDefaults.standard.set(newValue, forKey: "lineWidth") }
    }

    /// Extra space between lines as a fraction of the font size.
    static var lineSpacing: CGFloat {
        get { UserDefaults.standard.object(forKey: "lineSpacing") as? CGFloat ?? 0.32 }
        set { UserDefaults.standard.set(newValue, forKey: "lineSpacing") }
    }
}

extension Prefs {
    static var autoCheckUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }

    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "skippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }
}

extension Prefs {
    /// "system" (SF Mono) or a monospaced font family name.
    static var codeFont: String {
        get { UserDefaults.standard.string(forKey: "codeFont") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "codeFont") }
    }
}
