import AppKit

enum Bullets {
    private static let chars: [UniChar] = [0x2022, 0x25E6, 0x25AA] // • ◦ ▪

    static func glyph(level: Int, font: NSFont) -> CGGlyph? {
        for c in [chars[level % chars.count], chars[0]] {
            var ch = c
            var g: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font as CTFont, &ch, &g, 1) { return g }
        }
        return nil
    }
}

/// Hides markdown syntax outside the active paragraph, swaps list markers for bullets
/// and draws checkboxes, code backgrounds, quote bars and rules.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private(set) var activeRange = NSRange(location: NSNotFound, length: 0)
    var bodyFont = NSFont.systemFont(ofSize: 15)

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func isActive(_ i: Int) -> Bool {
        activeRange.location != NSNotFound && i >= activeRange.location && i < NSMaxRange(activeRange)
    }

    /// Moves the "revealed" paragraph and re-lays out only what changed.
    func activate(_ new: NSRange) {
        guard let ts = textStorage, new != activeRange else { return }
        let old = activeRange
        activeRange = new
        let len = ts.length
        let ns = ts.mutableString
        var ranges = [new]
        if old.location != NSNotFound, old.location <= len {
            ranges.append(ns.paragraphRange(for: NSRange(location: old.location, length: min(old.length, len - old.location))))
        }
        if new.location > 0, new.location <= len {
            ranges.append(ns.paragraphRange(for: NSRange(location: new.location - 1, length: 0)))
        }
        if NSMaxRange(new) < len {
            ranges.append(ns.paragraphRange(for: NSRange(location: NSMaxRange(new), length: 0)))
        }
        for r in ranges where r.length > 0 && NSMaxRange(r) <= len {
            invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
            invalidateDisplay(forCharacterRange: r)
        }
    }

    // MARK: - Glyph generation

    func layoutManager(_ lm: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let ts = textStorage else { return 0 }
        let count = glyphRange.length
        let length = ts.length
        var newProps: [NSLayoutManager.GlyphProperty]?
        var newGlyphs: [CGGlyph]?
        var cached = NSRange(location: 0, length: 0)
        var attrs: [NSAttributedString.Key: Any] = [:]

        for i in 0..<count {
            let ci = charIndexes[i]
            guard ci < length else { continue }
            if !NSLocationInRange(ci, cached) { attrs = ts.attributes(at: ci, effectiveRange: &cached) }
            if isHidden(attrs, ci) {
                // Zero-advance control glyphs (not .null, which the typesetter pulls onto the previous line).
                if newProps == nil { newProps = Array(UnsafeBufferPointer(start: props, count: count)) }
                newProps![i] = .controlCharacter
            } else if let level = attrs[.mdBullet] as? Int, let g = Bullets.glyph(level: level, font: aFont) {
                if newGlyphs == nil { newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count)) }
                newGlyphs![i] = g
            }
        }
        guard newProps != nil || newGlyphs != nil else { return 0 }
        let p = newProps ?? Array(UnsafeBufferPointer(start: props, count: count))
        let g = newGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: count))
        lm.setGlyphs(g, properties: p, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return count
    }

    private func isHidden(_ attrs: [NSAttributedString.Key: Any], _ ci: Int) -> Bool {
        attrs[.mdHidden] != nil || (attrs[.mdSyntax] != nil && !isActive(ci))
    }

    func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let ts = textStorage, charIndex < ts.length,
              isHidden(ts.attributes(at: charIndex, effectiveRange: nil), charIndex) else { return action }
        return .zeroAdvancement
    }

    // MARK: - Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, let tc = textContainers.first, ts.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: ts.length)

        // Fenced code blocks: one rounded panel per block.
        var drawn = Set<Int>()
        ts.enumerateAttribute(.mdCodeBlock, in: chars, options: []) { value, r, _ in
            guard let id = value as? Int, !drawn.contains(id) else { return }
            drawn.insert(id)
            var full = NSRange()
            _ = ts.attribute(.mdCodeBlock, at: r.location, longestEffectiveRange: &full, in: all)
            let g = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            var rect = NSRect.null
            enumerateLineFragments(forGlyphRange: g) { frag, _, _, fragGlyphs, _ in
                if self.fragment(fragGlyphs, startsWith: .mdCodeBlock, in: ts) { rect = rect.union(frag) }
            }
            guard !rect.isNull else { return }
            rect.origin.x = 0
            rect.size.width = tc.size.width
            Theme.codeBlockBackground.setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 8, yRadius: 8).fill()
        }

        drawPills(.mdInlineCode, Theme.inlineCodeBackground, in: chars, ts: ts, tc: tc, origin: origin)
        drawPills(.mdHighlight, Theme.highlight, in: chars, ts: ts, tc: tc, origin: origin)

        // Blockquote bars.
        ts.enumerateAttribute(.mdQuote, in: chars, options: []) { value, r, _ in
            guard value != nil else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: g) { frag, _, _, fragGlyphs, _ in
                guard self.fragment(fragGlyphs, startsWith: .mdQuote, in: ts) else { return }
                Theme.quoteBar.setFill()
                NSRect(x: origin.x + 1, y: origin.y + frag.minY, width: 3, height: frag.height).fill()
            }
        }

        // Horizontal rules (only when not being edited).
        ts.enumerateAttribute(.mdRule, in: chars, options: []) { value, r, _ in
            guard value != nil, !isActive(r.location) else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            guard g.length > 0 else { return }
            let used = lineFragmentUsedRect(forGlyphAt: g.location, effectiveRange: nil)
            let y = (origin.y + used.midY).rounded() - 0.5
            Theme.rule.setFill()
            NSRect(x: origin.x, y: y, width: tc.size.width, height: 1).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let ts = textStorage, ts.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        ts.enumerateAttribute(.mdCheckbox, in: chars, options: []) { value, r, _ in
            guard let checked = value as? Bool, let rect = checkboxRect(for: r) else { return }
            drawCheckbox(rect.offsetBy(dx: origin.x, dy: origin.y), checked: checked)
        }
    }

    /// Rounded background behind each line segment of an attributed run (inline code, highlights).
    private func drawPills(_ key: NSAttributedString.Key, _ color: NSColor, in chars: NSRange,
                           ts: NSTextStorage, tc: NSTextContainer, origin: NSPoint) {
        ts.enumerateAttribute(key, in: chars, options: []) { value, r, _ in
            guard value != nil else { return }
            let font = (ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont) ?? bodyFont
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: g) { frag, _, _, fragGlyphs, _ in
                let sub = NSIntersectionRange(g, fragGlyphs)
                guard sub.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: sub, in: tc)
                let baseline = frag.minY + self.location(forGlyphAt: sub.location).y
                rect.origin.y = baseline - font.ascender - 2
                rect.size.height = font.ascender - font.descender + 4
                rect = rect.insetBy(dx: -3, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    /// Hidden glyphs can be pulled onto a neighbouring line fragment; only count fragments
    /// whose first character actually carries the attribute.
    private func fragment(_ glyphs: NSRange, startsWith key: NSAttributedString.Key, in ts: NSTextStorage) -> Bool {
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.location < ts.length else { return false }
        return ts.attribute(key, at: chars.location, effectiveRange: nil) != nil
    }

    /// Checkbox frame in text-container coordinates.
    func checkboxRect(for charRange: NSRange) -> NSRect? {
        guard let tc = textContainers.first else { return nil }
        let g = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard g.length > 0 else { return nil }
        let frag = lineFragmentRect(forGlyphAt: g.location, effectiveRange: nil)
        let bounds = boundingRect(forGlyphRange: g, in: tc)
        let baseline = frag.minY + location(forGlyphAt: g.location).y
        let size = (bodyFont.pointSize * 0.95).rounded()
        let midY = baseline - bodyFont.capHeight / 2
        return NSRect(x: bounds.minX + 1, y: (midY - size / 2).rounded(), width: size, height: size)
    }

    private func drawCheckbox(_ r: NSRect, checked: Bool) {
        if checked {
            Theme.accent.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: r.minX + r.width * 0.26, y: r.minY + r.height * 0.52))
            check.line(to: NSPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.70))
            check.line(to: NSPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.32))
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Theme.checkmark.setStroke()
            check.stroke()
        } else {
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.6, yRadius: 3.6)
            box.lineWidth = 1.2
            Theme.secondary.setStroke()
            box.stroke()
        }
    }
}
