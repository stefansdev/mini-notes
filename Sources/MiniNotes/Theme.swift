import AppKit

enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let codeBlockBackground = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.055))
    static let inlineCodeBackground = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.09))
    static let inlineCodeText = dynamic(light: NSColor(srgbRed: 0.78, green: 0.20, blue: 0.32, alpha: 1),
                                        dark: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.56, alpha: 1))
    static let hover = dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.08))
    static let rowSelection = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.09))
    static let quoteBar = dynamic(light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.2))
    static let rule = dynamic(light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.14))
    static let paletteBackground = dynamic(light: NSColor(white: 0.985, alpha: 1),
                                           dark: NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1))
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.3)
    static let syntax = NSColor.tertiaryLabelColor
}
