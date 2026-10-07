import AppKit
import CoreText

/// Editor and code fonts: Apple's system fonts, open-source fonts bundled with the app
/// (SIL Open Font License, see Resources/Fonts/Licenses), and anything installed on the Mac.
enum FontLibrary {
    struct Choice {
        let id: String      // value stored in Prefs ("system", "rounded", … or a family name)
        let name: String    // shown in menus
    }

    static let builtInText: [Choice] = [
        Choice(id: "system", name: "SF Pro (System)"),
        Choice(id: "rounded", name: "SF Pro Rounded"),
        Choice(id: "serif", name: "New York"),
        Choice(id: "mono", name: "SF Mono"),
    ]

    static let bundledText: [Choice] = [
        Choice(id: "Inter", name: "Inter"),
        Choice(id: "Geist", name: "Geist"),
        Choice(id: "iA Writer Quattro V", name: "iA Writer Quattro"),
        Choice(id: "Atkinson Hyperlegible Next", name: "Atkinson Hyperlegible"),
        Choice(id: "Literata", name: "Literata"),
        Choice(id: "JetBrains Mono", name: "JetBrains Mono"),
    ]

    static let codeFonts: [Choice] = [
        Choice(id: "system", name: "SF Mono (System)"),
        Choice(id: "JetBrains Mono", name: "JetBrains Mono"),
        Choice(id: "Fira Code", name: "Fira Code"),
        Choice(id: "Geist Mono", name: "Geist Mono"),
        Choice(id: "IBM Plex Mono", name: "IBM Plex Mono"),
        Choice(id: "Menlo", name: "Menlo"),
    ]

    static var bundledFamilies: Set<String> {
        Set(bundledText.map(\.id) + codeFonts.map(\.id)).subtracting(["system", "Menlo"])
    }

    static func displayName(_ id: String) -> String {
        (builtInText + bundledText + codeFonts).first { $0.id == id }?.name ?? id
    }

    // MARK: - Registration

    /// Registers the bundled .ttf files for this process (call once at launch).
    static func registerBundledFonts() {
        guard let dir = fontsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let fonts = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    private static var fontsDirectory: URL? {
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           FileManager.default.fileExists(atPath: dir.path) { return dir }
        // `swift run` / debug builds: use the repo's Resources folder.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Resources/Fonts")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    // MARK: - Fonts

    /// Body/heading font for a text font id.
    static func textFont(_ id: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        switch id {
        case "system":
            return system
        case "rounded", "serif":
            let design: NSFontDescriptor.SystemDesign = id == "rounded" ? .rounded : .serif
            guard let d = system.fontDescriptor.withDesign(design) else { return system }
            return NSFont(descriptor: d, size: size) ?? system
        case "mono":
            return .monospacedSystemFont(ofSize: size, weight: weight)
        default:
            return family(id, size: size, weight: weight) ?? system
        }
    }

    /// Code font for a code font id.
    static func codeFont(_ id: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        return id == "system" ? system : (family(id, size: size, weight: weight) ?? system)
    }

    private static func family(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let bold = weight.rawValue >= NSFont.Weight.semibold.rawValue
        // NSFontManager weights: 5 = regular, 9 = bold.
        return NSFontManager.shared.font(withFamily: name, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size)
    }

    /// Installed families not already offered, optionally only monospaced ones.
    static func installedFamilies(monospacedOnly: Bool) -> [String] {
        let skip = bundledFamilies.union(["Menlo"])
        return NSFontManager.shared.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), !skip.contains(family) else { return false }
            guard monospacedOnly else { return true }
            return NSFont(name: family, size: 12)?.isFixedPitch ?? false
        }
    }
}
