import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// A color theme, modelled on the popular editor themes.
struct ThemeSpec {
    let id: String
    let name: String
    let dark: Bool
    let bg: UInt32         // window background
    let surface: UInt32    // code blocks, palette card
    let fg: UInt32         // body text
    let muted: UInt32      // secondary text, bullets, quotes
    let faint: UInt32      // markdown syntax, placeholders
    let accent: UInt32     // caret, checkboxes, links
    let code: UInt32       // inline code text
    let selection: UInt32  // text selection
    let border: UInt32
    let highlight: UInt32  // ==highlight==
}

/// A light/dark pair that follows the macOS appearance.
struct ThemeFamily {
    let id: String
    let name: String
    let light: String
    let dark: String
}

enum Themes {
    static let system = "system"

    static let all: [ThemeSpec] = [
        ThemeSpec(id: "vscode-dark", name: "VS Code Dark Modern", dark: true,
                  bg: 0x1F1F1F, surface: 0x181818, fg: 0xCCCCCC, muted: 0x9D9D9D, faint: 0x6E7681,
                  accent: 0x4DAAFC, code: 0xCE9178, selection: 0x264F78, border: 0x2B2B2B, highlight: 0xDCDCAA),
        ThemeSpec(id: "vscode-light", name: "VS Code Light Modern", dark: false,
                  bg: 0xFFFFFF, surface: 0xF8F8F8, fg: 0x3B3B3B, muted: 0x616161, faint: 0x8B8B8B,
                  accent: 0x005FB8, code: 0xA31515, selection: 0xADD6FF, border: 0xE5E5E5, highlight: 0xF5D90A),
        ThemeSpec(id: "github-dark", name: "GitHub Dark", dark: true,
                  bg: 0x0D1117, surface: 0x161B22, fg: 0xE6EDF3, muted: 0x9198A1, faint: 0x656C76,
                  accent: 0x4493F8, code: 0xFF7B72, selection: 0x1F3A5F, border: 0x30363D, highlight: 0xD29922),
        ThemeSpec(id: "github-light", name: "GitHub Light", dark: false,
                  bg: 0xFFFFFF, surface: 0xF6F8FA, fg: 0x1F2328, muted: 0x59636E, faint: 0x8C959F,
                  accent: 0x0969DA, code: 0xCF222E, selection: 0xB6D7FF, border: 0xD1D9E0, highlight: 0xD4A72C),
        ThemeSpec(id: "one-dark", name: "One Dark Pro", dark: true,
                  bg: 0x282C34, surface: 0x21252B, fg: 0xABB2BF, muted: 0x8B929E, faint: 0x5C6370,
                  accent: 0x61AFEF, code: 0xE06C75, selection: 0x3E4451, border: 0x3B4048, highlight: 0xE5C07B),
        ThemeSpec(id: "one-light", name: "One Light", dark: false,
                  bg: 0xFAFAFA, surface: 0xF0F0F1, fg: 0x383A42, muted: 0x696C77, faint: 0xA0A1A7,
                  accent: 0x4078F2, code: 0xE45649, selection: 0xE5E5E6, border: 0xDBDBDC, highlight: 0xC18401),
        ThemeSpec(id: "dracula", name: "Dracula", dark: true,
                  bg: 0x282A36, surface: 0x21222C, fg: 0xF8F8F2, muted: 0xBDBFCB, faint: 0x6272A4,
                  accent: 0xBD93F9, code: 0xFF79C6, selection: 0x44475A, border: 0x3A3C4E, highlight: 0xF1FA8C),
        ThemeSpec(id: "monokai", name: "Monokai", dark: true,
                  bg: 0x272822, surface: 0x1E1F1C, fg: 0xF8F8F2, muted: 0xCFCFC2, faint: 0x75715E,
                  accent: 0xA6E22E, code: 0xF92672, selection: 0x49483E, border: 0x3E3D32, highlight: 0xE6DB74),
        ThemeSpec(id: "nord", name: "Nord", dark: true,
                  bg: 0x2E3440, surface: 0x3B4252, fg: 0xECEFF4, muted: 0xD8DEE9, faint: 0x616E88,
                  accent: 0x88C0D0, code: 0xBF616A, selection: 0x434C5E, border: 0x434C5E, highlight: 0xEBCB8B),
        ThemeSpec(id: "tokyo-night", name: "Tokyo Night", dark: true,
                  bg: 0x1A1B26, surface: 0x16161E, fg: 0xC0CAF5, muted: 0xA9B1D6, faint: 0x565F89,
                  accent: 0x7AA2F7, code: 0xF7768E, selection: 0x283457, border: 0x292E42, highlight: 0xE0AF68),
        ThemeSpec(id: "catppuccin-mocha", name: "Catppuccin Mocha", dark: true,
                  bg: 0x1E1E2E, surface: 0x181825, fg: 0xCDD6F4, muted: 0xA6ADC8, faint: 0x6C7086,
                  accent: 0xCBA6F7, code: 0xF38BA8, selection: 0x45475A, border: 0x313244, highlight: 0xF9E2AF),
        ThemeSpec(id: "catppuccin-latte", name: "Catppuccin Latte", dark: false,
                  bg: 0xEFF1F5, surface: 0xE6E9EF, fg: 0x4C4F69, muted: 0x6C6F85, faint: 0x9CA0B0,
                  accent: 0x8839EF, code: 0xD20F39, selection: 0xCCD0DA, border: 0xCCD0DA, highlight: 0xDF8E1D),
        ThemeSpec(id: "gruvbox-dark", name: "Gruvbox Dark", dark: true,
                  bg: 0x282828, surface: 0x32302F, fg: 0xEBDBB2, muted: 0xBDAE93, faint: 0x7C6F64,
                  accent: 0xFABD2F, code: 0xFE8019, selection: 0x504945, border: 0x3C3836, highlight: 0xFABD2F),
        ThemeSpec(id: "gruvbox-light", name: "Gruvbox Light", dark: false,
                  bg: 0xFBF1C7, surface: 0xF2E5BC, fg: 0x3C3836, muted: 0x665C54, faint: 0xA89984,
                  accent: 0x076678, code: 0x9D0006, selection: 0xEBDBB2, border: 0xD5C4A1, highlight: 0xB57614),
        ThemeSpec(id: "solarized-dark", name: "Solarized Dark", dark: true,
                  bg: 0x002B36, surface: 0x073642, fg: 0x93A1A1, muted: 0x839496, faint: 0x586E75,
                  accent: 0x268BD2, code: 0xD33682, selection: 0x274642, border: 0x0B4554, highlight: 0xB58900),
        ThemeSpec(id: "solarized-light", name: "Solarized Light", dark: false,
                  bg: 0xFDF6E3, surface: 0xEEE8D5, fg: 0x586E75, muted: 0x657B83, faint: 0x93A1A1,
                  accent: 0x268BD2, code: 0xD33682, selection: 0xE4DCC0, border: 0xE4DDC8, highlight: 0xB58900),
        ThemeSpec(id: "rose-pine", name: "Rosé Pine", dark: true,
                  bg: 0x191724, surface: 0x1F1D2E, fg: 0xE0DEF4, muted: 0x908CAA, faint: 0x6E6A86,
                  accent: 0xC4A7E7, code: 0xEBBCBA, selection: 0x403D52, border: 0x26233A, highlight: 0xF6C177),
        ThemeSpec(id: "rose-pine-dawn", name: "Rosé Pine Dawn", dark: false,
                  bg: 0xFAF4ED, surface: 0xFFFAF3, fg: 0x575279, muted: 0x797593, faint: 0x9893A5,
                  accent: 0x907AA9, code: 0xB4637A, selection: 0xDFDAD9, border: 0xDFDAD9, highlight: 0xEA9D34),
    ]

    static let families: [ThemeFamily] = [
        ThemeFamily(id: "vscode", name: "VS Code", light: "vscode-light", dark: "vscode-dark"),
        ThemeFamily(id: "github", name: "GitHub", light: "github-light", dark: "github-dark"),
        ThemeFamily(id: "one", name: "One", light: "one-light", dark: "one-dark"),
        ThemeFamily(id: "catppuccin", name: "Catppuccin", light: "catppuccin-latte", dark: "catppuccin-mocha"),
        ThemeFamily(id: "gruvbox", name: "Gruvbox", light: "gruvbox-light", dark: "gruvbox-dark"),
        ThemeFamily(id: "solarized", name: "Solarized", light: "solarized-light", dark: "solarized-dark"),
        ThemeFamily(id: "rose-pine-auto", name: "Rosé Pine", light: "rose-pine-dawn", dark: "rose-pine"),
    ]

    /// Code token colors per theme: keyword, string, number, comment, type, function.
    static let tokenColors: [String: [UInt32]] = [
        "vscode-dark":      [0x569CD6, 0xCE9178, 0xB5CEA8, 0x6A9955, 0x4EC9B0, 0xDCDCAA],
        "vscode-light":     [0x0000FF, 0xA31515, 0x098658, 0x008000, 0x267F99, 0x795E26],
        "github-dark":      [0xFF7B72, 0xA5D6FF, 0x79C0FF, 0x8B949E, 0xFFA657, 0xD2A8FF],
        "github-light":     [0xCF222E, 0x0A3069, 0x0550AE, 0x6E7781, 0x953800, 0x8250DF],
        "one-dark":         [0xC678DD, 0x98C379, 0xD19A66, 0x7F848E, 0xE5C07B, 0x61AFEF],
        "one-light":        [0xA626A4, 0x50A14F, 0x986801, 0xA0A1A7, 0xC18401, 0x4078F2],
        "dracula":          [0xFF79C6, 0xF1FA8C, 0xBD93F9, 0x6272A4, 0x8BE9FD, 0x50FA7B],
        "monokai":          [0xF92672, 0xE6DB74, 0xAE81FF, 0x75715E, 0x66D9EF, 0xA6E22E],
        "nord":             [0x81A1C1, 0xA3BE8C, 0xB48EAD, 0x616E88, 0x8FBCBB, 0x88C0D0],
        "tokyo-night":      [0xBB9AF7, 0x9ECE6A, 0xFF9E64, 0x565F89, 0x2AC3DE, 0x7AA2F7],
        "catppuccin-mocha": [0xCBA6F7, 0xA6E3A1, 0xFAB387, 0x9399B2, 0xF9E2AF, 0x89B4FA],
        "catppuccin-latte": [0x8839EF, 0x40A02B, 0xFE640B, 0x7C7F93, 0xDF8E1D, 0x1E66F5],
        "gruvbox-dark":     [0xFB4934, 0xB8BB26, 0xD3869B, 0x928374, 0xFABD2F, 0x8EC07C],
        "gruvbox-light":    [0x9D0006, 0x79740E, 0x8F3F71, 0x928374, 0xB57614, 0x427B58],
        "solarized-dark":   [0x859900, 0x2AA198, 0xD33682, 0x586E75, 0xB58900, 0x268BD2],
        "solarized-light":  [0x859900, 0x2AA198, 0xD33682, 0x93A1A1, 0xB58900, 0x268BD2],
        "rose-pine":        [0x31748F, 0xF6C177, 0xEB6F92, 0x6E6A86, 0x9CCFD8, 0xEBBCBA],
        "rose-pine-dawn":   [0x286983, 0xEA9D34, 0xB4637A, 0x9893A5, 0x56949F, 0xD7827E],
    ]

    static func spec(_ id: String) -> ThemeSpec? { all.first { $0.id == id } }
    static func family(_ id: String) -> ThemeFamily? { families.first { $0.id == id } }

    /// Resolves a selectable id (`system`, a family, or a concrete theme) to the colors to use; nil means System.
    static func resolve(_ id: String, systemDark: Bool) -> ThemeSpec? {
        if let f = family(id) { return spec(systemDark ? f.dark : f.light) }
        return spec(id)
    }

    static func name(_ id: String) -> String {
        if id == system { return "System" }
        if let f = family(id) { return "\(f.name) (Auto)" }
        return spec(id)?.name ?? "System"
    }

    /// Small preview chip for menus and the theme picker.
    static func swatch(_ id: String) -> NSImage? {
        let specs: [ThemeSpec]
        if let f = family(id), let l = spec(f.light), let d = spec(f.dark) {
            specs = [l, d]
        } else if let s = spec(id) {
            specs = [s]
        } else {
            return nil
        }
        return NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            for (i, s) in specs.enumerated() {
                let w = rect.width / CGFloat(specs.count)
                let part = NSRect(x: rect.minX + w * CGFloat(i), y: rect.minY, width: w, height: rect.height)
                NSColor(hex: s.bg).setFill()
                part.fill()
                NSColor(hex: s.fg, alpha: 0.85).setFill()
                NSRect(x: part.minX + 3, y: rect.midY + 1, width: max(3, part.width - 8), height: 2).fill()
                NSColor(hex: s.accent).setFill()
                NSBezierPath(ovalIn: NSRect(x: part.minX + 3, y: rect.minY + 3, width: 5, height: 5)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0.5, alpha: 0.4).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
    }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("MiniNotes.themeDidChange")
    static let editorSettingsDidChange = Notification.Name("MiniNotes.editorSettingsDidChange")
}

/// Owns the selected theme and re-resolves "auto" themes when macOS switches light/dark.
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()
    private(set) var selectedID: String
    private var observation: NSKeyValueObservation?

    private init() {
        selectedID = Prefs.themeID
        resolve()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async {
                guard Themes.family(ThemeManager.shared.selectedID) != nil else { return }
                ThemeManager.shared.resolve()
                NotificationCenter.default.post(name: .themeDidChange, object: nil)
            }
        }
    }

    /// `persist: false` previews a theme without saving it.
    func select(_ id: String, persist: Bool = true) {
        if persist { Prefs.themeID = id }
        guard id != selectedID else { return }
        selectedID = id
        resolve()
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    private func resolve() {
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Theme.spec = Themes.resolve(selectedID, systemDark: systemDark)
    }
}

/// The colors everything draws with. `spec == nil` is the System theme (translucent, follows macOS).
enum Theme {
    static var spec: ThemeSpec?

    private static func c(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor { NSColor(hex: hex, alpha: alpha) }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static var appearance: NSAppearance? { spec.map { NSAppearance(named: $0.dark ? .darkAqua : .aqua)! } }
    static var background: NSColor? { spec.map { c($0.bg) } }

    static var text: NSColor { spec.map { c($0.fg) } ?? .labelColor }
    static var secondary: NSColor { spec.map { c($0.muted) } ?? .secondaryLabelColor }
    static var tertiary: NSColor { spec.map { c($0.faint) } ?? .tertiaryLabelColor }
    static var syntax: NSColor { tertiary }
    static var accent: NSColor { spec.map { c($0.accent) } ?? .controlAccentColor }
    static var link: NSColor { spec.map { c($0.accent) } ?? .linkColor }
    static var separator: NSColor { spec.map { c($0.border) } ?? .separatorColor }
    static var textSelection: NSColor { spec.map { c($0.selection) } ?? .selectedTextBackgroundColor }
    /// Checkmark inside a filled checkbox: dark themes often have light accents, so use the background.
    static var checkmark: NSColor { spec.map { $0.dark ? c($0.bg) : .white } ?? .white }

    static var codeBlockBackground: NSColor {
        spec.map { c($0.surface) } ?? dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.055))
    }
    static var inlineCodeBackground: NSColor {
        spec.map { c($0.fg, 0.09) } ?? dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.09))
    }
    static var inlineCodeText: NSColor {
        spec.map { c($0.code) } ?? dynamic(light: NSColor(srgbRed: 0.78, green: 0.20, blue: 0.32, alpha: 1),
                                          dark: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.56, alpha: 1))
    }
    static var hover: NSColor {
        spec.map { c($0.fg, 0.08) } ?? dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    }
    static var rowSelection: NSColor {
        spec.map { c($0.fg, 0.1) } ?? dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.09))
    }
    static var quoteBar: NSColor {
        spec.map { c($0.faint, 0.7) } ?? dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.2))
    }
    static var rule: NSColor {
        spec.map { c($0.faint, 0.45) } ?? dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    }
    static var highlight: NSColor { spec.map { c($0.highlight, 0.3) } ?? NSColor.systemYellow.withAlphaComponent(0.3) }
    /// Xcode's default colors for the System theme.
    private static let systemTokens: [(UInt32, UInt32)] = [   // (light, dark)
        (0x9B2393, 0xFF7AB2), (0xC41A16, 0xFF8170), (0x1C00CF, 0xD9C97C),
        (0x5D6C79, 0x7F8C98), (0x0F68A0, 0x5DD8FF), (0x326D74, 0x67B7A4),
    ]

    static func token(_ kind: TokenKind) -> NSColor {
        if let spec, let colors = Themes.tokenColors[spec.id] { return c(colors[kind.rawValue]) }
        let pair = systemTokens[kind.rawValue]
        return dynamic(light: c(pair.0), dark: c(pair.1))
    }

    static var paletteBackground: NSColor {
        spec.map { c($0.surface) } ?? dynamic(light: NSColor(white: 0.985, alpha: 1),
                                             dark: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1))
    }
}
