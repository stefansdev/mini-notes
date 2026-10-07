import AppKit

extension NSAttributedString.Key {
    /// Markdown syntax characters; hidden unless the caret is on that paragraph.
    static let mdSyntax = NSAttributedString.Key("mn.syntax")
    /// Characters that are never drawn (the `- ` in front of a checkbox).
    static let mdHidden = NSAttributedString.Key("mn.hidden")
    /// List marker rendered as a bullet glyph. Value: nesting level (Int).
    static let mdBullet = NSAttributedString.Key("mn.bullet")
    /// `[ ]` / `[x]` rendered as a checkbox. Value: checked (Bool).
    static let mdCheckbox = NSAttributedString.Key("mn.checkbox")
    static let mdInlineCode = NSAttributedString.Key("mn.inlineCode")
    /// Fenced code block. Value: block index (Int), so adjacent blocks stay separate.
    static let mdCodeBlock = NSAttributedString.Key("mn.codeBlock")
    static let mdQuote = NSAttributedString.Key("mn.quote")
    static let mdRule = NSAttributedString.Key("mn.rule")
    /// Value: URL string, opened with ⌘-click.
    static let mdLink = NSAttributedString.Key("mn.link")
    static let mdHighlight = NSAttributedString.Key("mn.highlight")
}

/// Applies markdown styling to the text storage as it is edited.
/// Only the edited paragraphs are restyled, unless a code fence was added or removed.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    var baseSize: CGFloat { didSet { makeFonts() } }

    private(set) var body = NSFont.systemFont(ofSize: 15)
    private(set) var mono = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    private(set) var bodyPara = NSParagraphStyle()
    private var monoSmall = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var spaceWidth: CGFloat = 4
    private var codePara = NSParagraphStyle()
    private var fencePara = NSParagraphStyle()
    private var quotePara = NSParagraphStyle()
    private var headingFonts: [NSFont] = []
    private var headingParas: [NSParagraphStyle] = []
    private var bulletWidths: [CGFloat] = []
    private var fenceCount = -1

    static let indentKern: CGFloat = 7
    static let tabWidth: CGFloat = 24

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyPara]
    }

    init(baseSize: CGFloat) {
        self.baseSize = baseSize
        super.init()
        makeFonts()
    }

    // MARK: - Regexes

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let headingRE = re(#"^(#{1,6})[ \t]+"#)
    private static let ruleRE = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let quoteRE = re(#"^ {0,3}>[ \t]?"#)
    private static let taskRE = re(#"^([ \t]*)([-*+][ \t]+)(\[[ xX]\])(?=[ \t]|$)"#)
    private static let bulletRE = re(#"^([ \t]*)([-*+])([ \t]+)"#)
    private static let orderedRE = re(#"^([ \t]*)(\d{1,9}[.)])([ \t]+)"#)
    private static let codeRE = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let boldRE = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStarRE = re(#"(?<![*\\])\*(?![\s*])(.+?)(?<![\s*\\])\*(?!\*)"#)
    private static let italicUnderRE = re(#"(?<![\w_\\])_(?![\s_])(.+?)(?<![\s_\\])_(?![\w_])"#)
    private static let strikeRE = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let highlightRE = re(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let linkRE = re(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let urlRE = re(#"\b(?:https?://|www\.)[^\s<>()\[\]]*[^\s<>()\[\].,;:!?"']"#)

    // MARK: - Fonts

    private func makeFonts() {
        body = .systemFont(ofSize: baseSize)
        mono = .monospacedSystemFont(ofSize: (baseSize * 0.9 * 2).rounded() / 2, weight: .regular)
        monoSmall = .monospacedSystemFont(ofSize: baseSize - 3, weight: .medium)
        spaceWidth = (" " as NSString).size(withAttributes: [.font: body]).width

        let p = NSMutableParagraphStyle()
        p.lineSpacing = (baseSize * 0.32).rounded()
        p.paragraphSpacing = 2
        p.defaultTabInterval = Self.tabWidth
        p.tabStops = []
        bodyPara = p.copy() as! NSParagraphStyle

        let c = p.mutableCopy() as! NSMutableParagraphStyle
        c.lineSpacing = 3
        c.paragraphSpacing = 0
        c.firstLineHeadIndent = 14
        c.headIndent = 14
        c.tailIndent = -14
        codePara = c.copy() as! NSParagraphStyle
        c.minimumLineHeight = (baseSize * 1.75).rounded()
        fencePara = c.copy() as! NSParagraphStyle

        let q = p.mutableCopy() as! NSMutableParagraphStyle
        q.firstLineHeadIndent = 16
        q.headIndent = 16
        quotePara = q.copy() as! NSParagraphStyle

        let scales: [CGFloat] = [1.6, 1.33, 1.13, 1, 1, 1]
        headingFonts = scales.enumerated().map { i, s in
            .systemFont(ofSize: (baseSize * s).rounded(), weight: i < 2 ? .bold : .semibold)
        }
        headingParas = [12, 10, 6, 4, 4, 4].map { (before: CGFloat) -> NSParagraphStyle in
            let h = p.mutableCopy() as! NSMutableParagraphStyle
            h.paragraphSpacingBefore = before
            h.paragraphSpacing = 4
            return h.copy() as! NSParagraphStyle
        }
        bulletWidths = (0..<3).map { level in
            guard let g = Bullets.glyph(level: level, font: body) else { return spaceWidth }
            return body.advancement(forCGGlyph: g).width
        }
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ ts: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let ns = ts.mutableString
        let fences = Self.countFences(ns, upTo: ns.length)
        if fences != fenceCount {
            fenceCount = fences
            style(ts, range: NSRange(location: 0, length: ns.length))
        } else {
            style(ts, range: ns.paragraphRange(for: editedRange))
        }
    }

    /// Restyle everything (e.g. after a font size change). Call between begin/endEditing.
    func styleAll(_ ts: NSTextStorage) {
        fenceCount = Self.countFences(ts.mutableString, upTo: ts.length)
        style(ts, range: NSRange(location: 0, length: ts.length))
    }

    // MARK: - Block level

    static func isFence(_ ns: NSString, _ start: Int, _ contentsEnd: Int) -> Bool {
        var i = start
        var spaces = 0
        while i < contentsEnd, spaces < 3, ns.character(at: i) == 0x20 { i += 1; spaces += 1 }
        guard contentsEnd - i >= 3 else { return false }
        return ns.character(at: i) == 0x60 && ns.character(at: i + 1) == 0x60 && ns.character(at: i + 2) == 0x60
    }

    static func countFences(_ ns: NSString, upTo limit: Int) -> Int {
        var count = 0, loc = 0
        let len = ns.length
        while loc < limit, loc < len {
            var s = 0, e = 0, ce = 0
            ns.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: loc, length: 0))
            if isFence(ns, s, ce) { count += 1 }
            if e <= loc { break }
            loc = e
        }
        return count
    }

    private func style(_ ts: NSTextStorage, range: NSRange) {
        let ns = ts.mutableString
        guard ns.length > 0, range.length > 0 else { return }
        var fencesBefore = Self.countFences(ns, upTo: range.location)
        var loc = range.location
        let end = NSMaxRange(range)
        while loc < end {
            var s = 0, e = 0, ce = 0
            ns.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: loc, length: 0))
            let full = NSRange(location: s, length: e - s)
            let content = NSRange(location: s, length: ce - s)
            ts.setAttributes(baseAttributes, range: full)
            let fence = Self.isFence(ns, s, ce)
            if fence || fencesBefore % 2 == 1 {
                styleCode(ts, ns, full: full, content: content, fence: fence, block: fencesBefore / 2)
                if fence { fencesBefore += 1 }
            } else if content.length > 0 {
                styleLine(ts, ns.substring(with: content), offset: s, fullLength: full.length)
            }
            if e <= loc { break }
            loc = e
        }
    }

    private func styleCode(_ ts: NSTextStorage, _ ns: NSString, full: NSRange, content: NSRange, fence: Bool, block: Int) {
        ts.addAttributes([.font: mono, .paragraphStyle: codePara, .mdCodeBlock: block], range: full)
        guard fence else { return }
        ts.addAttributes([.font: monoSmall, .foregroundColor: Theme.syntax, .paragraphStyle: fencePara], range: full)
        var i = content.location
        while i < NSMaxRange(content), ns.character(at: i) == 0x20 { i += 1 }
        var j = i
        while j < NSMaxRange(content), ns.character(at: j) == 0x60 { j += 1 }
        ts.addAttribute(.mdSyntax, value: true, range: NSRange(location: i, length: j - i))
    }

    private func styleLine(_ ts: NSTextStorage, _ line: String, offset: Int, fullLength: Int) {
        let ls = line as NSString
        let len = ls.length
        let whole = NSRange(location: 0, length: len)
        let lineFull = NSRange(location: offset, length: fullLength)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func syntax(_ r: NSRange) {
            guard r.length > 0 else { return }
            ts.addAttributes([.foregroundColor: Theme.syntax, .mdSyntax: true], range: abs(r))
        }
        func hangingIndent(_ w: CGFloat) {
            let p = bodyPara.mutableCopy() as! NSMutableParagraphStyle
            p.headIndent = w
            ts.addAttribute(.paragraphStyle, value: p, range: lineFull)
        }

        var inlineStart = 0
        let first = ls.character(at: 0)

        if first == 0x23 /* # */, let m = Self.headingRE.firstMatch(in: line, range: whole) {
            let level = min(6, m.range(at: 1).length)
            ts.addAttributes([.font: headingFonts[level - 1], .paragraphStyle: headingParas[level - 1]], range: lineFull)
            syntax(m.range)
            inlineStart = m.range.length
        } else if Self.ruleRE.firstMatch(in: line, range: whole) != nil {
            ts.addAttribute(.mdRule, value: true, range: abs(whole))
            syntax(whole)
            return
        } else if let m = Self.quoteRE.firstMatch(in: line, range: whole) {
            ts.addAttributes([.mdQuote: true, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: quotePara], range: lineFull)
            syntax(m.range)
            inlineStart = m.range.length
        } else if let m = Self.taskRE.firstMatch(in: line, range: whole) {
            let indent = m.range(at: 1), dash = m.range(at: 2), box = m.range(at: 3)
            let checked = ls.substring(with: box) != "[ ]"
            let indentW = applyIndent(ts, ls, indent, offset)
            ts.addAttributes([.mdHidden: true, .foregroundColor: Theme.syntax], range: abs(dash))
            ts.addAttributes([.mdCheckbox: checked, .foregroundColor: NSColor.clear], range: abs(box))
            ts.addAttribute(.kern, value: 4, range: abs(NSRange(location: NSMaxRange(box) - 1, length: 1)))
            let boxW = ls.substring(with: box).size(withAttributes: [.font: body]).width + 4
            let rest = NSRange(location: NSMaxRange(box), length: len - NSMaxRange(box))
            var restStart = rest.location
            while restStart < len, ls.character(at: restStart) == 0x20 || ls.character(at: restStart) == 0x09 { restStart += 1 }
            if checked, restStart < len {
                ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: abs(rest))
                ts.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor,
                                  .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                  .strikethroughColor: NSColor.tertiaryLabelColor],
                                 range: abs(NSRange(location: restStart, length: len - restStart)))
            }
            hangingIndent(indentW + boxW + (rest.length > 0 ? spaceWidth : 0))
            inlineStart = NSMaxRange(box)
        } else if let m = Self.bulletRE.firstMatch(in: line, range: whole) {
            let indent = m.range(at: 1), marker = m.range(at: 2), gap = m.range(at: 3)
            let level = indentLevel(ls, indent)
            let indentW = applyIndent(ts, ls, indent, offset)
            ts.addAttributes([.mdBullet: level, .foregroundColor: NSColor.secondaryLabelColor], range: abs(marker))
            hangingIndent(indentW + bulletWidths[level % bulletWidths.count] + CGFloat(gap.length) * spaceWidth)
            inlineStart = m.range.length
        } else if let m = Self.orderedRE.firstMatch(in: line, range: whole) {
            let indent = m.range(at: 1), marker = m.range(at: 2), gap = m.range(at: 3)
            let indentW = applyIndent(ts, ls, indent, offset)
            ts.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: abs(marker))
            let markerW = ls.substring(with: marker).size(withAttributes: [.font: body]).width
            hangingIndent(indentW + markerW + CGFloat(gap.length) * spaceWidth)
            inlineStart = m.range.length
        }

        if inlineStart < len {
            styleInline(ts, line, ls, NSRange(location: inlineStart, length: len - inlineStart), offset)
        }
    }

    /// Widens leading spaces (via kerning) so 2-space nesting reads as a real indent. Returns its width.
    private func applyIndent(_ ts: NSTextStorage, _ ls: NSString, _ r: NSRange, _ offset: Int) -> CGFloat {
        var w: CGFloat = 0
        for i in r.location..<NSMaxRange(r) {
            if ls.character(at: i) == 0x09 {
                w = ((w / Self.tabWidth).rounded(.down) + 1) * Self.tabWidth
            } else {
                w += spaceWidth + Self.indentKern
                ts.addAttribute(.kern, value: Self.indentKern, range: NSRange(location: offset + i, length: 1))
            }
        }
        return w
    }

    private func indentLevel(_ ls: NSString, _ r: NSRange) -> Int {
        var spaces = 0, tabs = 0
        for i in r.location..<NSMaxRange(r) {
            if ls.character(at: i) == 0x09 { tabs += 1 } else { spaces += 1 }
        }
        return tabs + spaces / 2
    }

    // MARK: - Inline

    private func styleInline(_ ts: NSTextStorage, _ line: String, _ ls: NSString, _ range: NSRange, _ offset: Int) {
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func syntax(_ r: NSRange) {
            guard r.length > 0 else { return }
            ts.addAttributes([.foregroundColor: Theme.syntax, .mdSyntax: true], range: abs(r))
        }
        var protected: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !protected.contains { NSIntersectionRange($0, r).length > 0 } }
        func has(_ s: String) -> Bool { ls.range(of: s).location != NSNotFound }

        if has("`") {
            for m in Self.codeRE.matches(in: line, range: range) {
                let r = m.range, ticks = m.range(at: 1).length
                ts.addAttributes([.font: mono, .mdInlineCode: true, .foregroundColor: Theme.inlineCodeText], range: abs(r))
                syntax(NSRange(location: r.location, length: ticks))
                syntax(NSRange(location: NSMaxRange(r) - ticks, length: ticks))
                protected.append(r)
            }
        }
        if has("](") {
            for m in Self.linkRE.matches(in: line, range: range) where free(m.range) {
                let text = m.range(at: 1)
                ts.addAttributes([.foregroundColor: NSColor.linkColor, .mdLink: ls.substring(with: m.range(at: 2))], range: abs(text))
                syntax(NSRange(location: m.range.location, length: 1))
                let tail = NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text))
                syntax(tail)
                protected.append(tail)
            }
        }
        if has("http") || has("www.") {
            for m in Self.urlRE.matches(in: line, range: range) where free(m.range) {
                ts.addAttributes([.foregroundColor: NSColor.linkColor,
                                  .mdLink: ls.substring(with: m.range),
                                  .underlineStyle: NSUnderlineStyle.single.rawValue,
                                  .underlineColor: NSColor.linkColor.withAlphaComponent(0.35)], range: abs(m.range))
                protected.append(m.range)
            }
        }

        func emphasis(_ re: NSRegularExpression, _ marker: Int, _ apply: (NSRange) -> Void) {
            for m in re.matches(in: line, range: range) where free(m.range) {
                let r = m.range
                apply(abs(NSRange(location: r.location + marker, length: r.length - 2 * marker)))
                syntax(NSRange(location: r.location, length: marker))
                syntax(NSRange(location: NSMaxRange(r) - marker, length: marker))
            }
        }
        if has("**") || has("__") { emphasis(Self.boldRE, 2) { addTraits(ts, .bold, $0) } }
        if has("*") { emphasis(Self.italicStarRE, 1) { addTraits(ts, .italic, $0) } }
        if has("_") { emphasis(Self.italicUnderRE, 1) { addTraits(ts, .italic, $0) } }
        if has("~~") {
            emphasis(Self.strikeRE, 2) {
                ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                  .foregroundColor: NSColor.secondaryLabelColor], range: $0)
            }
        }
        if has("==") { emphasis(Self.highlightRE, 2) { ts.addAttribute(.mdHighlight, value: true, range: $0) } }
    }

    private func addTraits(_ ts: NSTextStorage, _ traits: NSFontDescriptor.SymbolicTraits, _ r: NSRange) {
        ts.enumerateAttribute(.font, in: r, options: []) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            if let f = NSFont(descriptor: d, size: font.pointSize) {
                ts.addAttribute(.font, value: f, range: sub)
            }
        }
    }
}
