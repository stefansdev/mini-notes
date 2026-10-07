import AppKit
import Carbon.HIToolbox

enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "hotKeyCode": kVK_ANSI_N,
            "hotKeyMods": cmdKey | optionKey,
            "hotKeyDisplay": "⌥⌘N",
            "floatOnTop": false,
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
