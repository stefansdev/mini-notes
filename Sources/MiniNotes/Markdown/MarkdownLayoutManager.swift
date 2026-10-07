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
        isFolded(ci) || attrs[.mdHidden] != nil || (attrs[.mdSyntax] != nil && !isActive(ci))
    }

    // MARK: - Folding

    /// Line-start indexes of folded headings → the character range each one hides.
    private(set) var folds: [Int: NSRange] = [:]

    func isFolded(_ ci: Int) -> Bool {
        for r in folds.values where ci >= r.location && ci < NSMaxRange(r) { return true }
        return false
    }

    /// Heading level (1–6) of the line starting at `lineStart`, ignoring code blocks.
    func headingLevel(at lineStart: Int) -> Int? {
        guard let ts = textStorage, lineStart < ts.length else { return nil }
        if ts.attribute(.mdCodeBlock, at: lineStart, effectiveRange: nil) != nil { return nil }
        let ns = ts.mutableString
        var i = lineStart, level = 0
        while i < ns.length, ns.character(at: i) == 0x23, level < 7 { level += 1; i += 1 }
        guard (1...6).contains(level), i < ns.length, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 else { return nil }
        return level
    }

    /// What folding the heading at `lineStart` would hide: its line break and everything up to the
    /// line break before the next heading of the same or higher level.
    func foldRange(forHeadingAt lineStart: Int) -> NSRange? {
        guard let ts = textStorage, let level = headingLevel(at: lineStart) else { return nil }
        let ns = ts.mutableString
        var s = 0, e = 0, ce = 0
        ns.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: lineStart, length: 0))
        let hideFrom = ce
        var loc = e
        var end = ns.length
        while loc < ns.length {
            var ls = 0, le = 0, lce = 0
            ns.getLineStart(&ls, end: &le, contentsEnd: &lce, for: NSRange(location: loc, length: 0))
            if let l = headingLevel(at: ls), l <= level { end = ls - 1; break }   // keep the break before it
            if le <= loc { break }
            loc = le
        }
        guard end > hideFrom else { return nil }
        // Don't fold a section that's only blank lines.
        let hidden = NSRange(location: hideFrom, length: end - hideFrom)
        guard ns.substring(with: hidden).contains(where: { !$0.isWhitespace }) else { return nil }
        return hidden
    }

    func isFoldable(_ lineStart: Int) -> Bool { foldRange(forHeadingAt: lineStart) != nil }

    /// Folds or unfolds the heading at `lineStart`. Returns false if there's nothing to fold.
    @discardableResult
    func toggleFold(at lineStart: Int) -> Bool {
        if let r = folds.removeValue(forKey: lineStart) {
            invalidateFold(lineStart, r)
            return true
        }
        guard let r = foldRange(forHeadingAt: lineStart) else { return false }
        folds[lineStart] = r
        invalidateFold(lineStart, r)
        return true
    }

    func unfoldAll() {
        let old = folds
        folds = [:]
        for (start, r) in old { invalidateFold(start, r) }
    }

    func setFolds(_ starts: Set<Int>) {
        unfoldAll()
        for s in starts.sorted() { if let r = foldRange(forHeadingAt: s) { folds[s] = r; invalidateFold(s, r) } }
    }

    /// Unfolds any section whose hidden text contains `ci` (e.g. the caret moved there).
    @discardableResult
    func unfold(containing ci: Int) -> Bool {
        var changed = false
        for (start, r) in folds where ci > r.location && ci <= NSMaxRange(r) {
            folds[start] = nil
            invalidateFold(start, r)
            changed = true
        }
        return changed
    }

    /// Keeps folds pointing at the right headings after a text edit (call with the post-edit range).
    func adjustFolds(edited: NSRange, delta: Int) {
        guard !folds.isEmpty else { return }
        let before = NSRange(location: edited.location, length: max(0, edited.length - delta))
        var kept = Set<Int>()
        for (start, r) in folds {
            let span = NSRange(location: start, length: NSMaxRange(r) - start)
            if before.location < start, NSMaxRange(before) <= start {
                kept.insert(start + delta)          // edit entirely before the heading
            } else if before.location >= NSMaxRange(span) {
                kept.insert(start)                  // edit after the folded section
            }                                       // edit touching the section: unfold
        }
        folds = [:]
        for s in kept { if let r = foldRange(forHeadingAt: s) { folds[s] = r } }
    }

    private func invalidateFold(_ start: Int, _ r: NSRange) {
        guard let ts = textStorage else { return }
        let span = NSRange(location: start, length: min(NSMaxRange(r), ts.length) - start)
        invalidateGlyphs(forCharacterRange: span, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: span, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: NSRange(location: start, length: ts.length - start))
    }

    /// Frame (container coordinates) of the "⋯" pill drawn after a folded heading.
    func foldPillRect(forHeadingAt start: Int) -> NSRect? {
        guard let r = folds[start], let tc = textContainers.first, r.location > start else { return nil }
        let g = glyphRange(forCharacterRange: NSRange(location: start, length: r.location - start), actualCharacterRange: nil)
        guard g.length > 0 else { return nil }
        let text = boundingRect(forGlyphRange: g, in: tc)
        let frag = lineFragmentUsedRect(forGlyphAt: g.location, effectiveRange: nil)
        return NSRect(x: text.maxX + 8, y: frag.minY + (frag.height - 16) / 2 - 1, width: 26, height: 16)
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
            guard let id = value as? Int, !drawn.contains(id), !isFolded(r.location) else { return }
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
            guard value != nil, !isFolded(r.location) else { return }
            let g = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: g) { frag, _, _, fragGlyphs, _ in
                guard self.fragment(fragGlyphs, startsWith: .mdQuote, in: ts) else { return }
                Theme.quoteBar.setFill()
                NSRect(x: origin.x + 1, y: origin.y + frag.minY, width: 3, height: frag.height).fill()
            }
        }

        // Horizontal rules (only when not being edited).
        ts.enumerateAttribute(.mdRule, in: chars, options: []) { value, r, _ in
            guard value != nil, !isActive(r.location), !isFolded(r.location) else { return }
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
            guard let checked = value as? Bool, !isFolded(r.location), let rect = checkboxRect(for: r) else { return }
            drawCheckbox(rect.offsetBy(dx: origin.x, dy: origin.y), checked: checked)
        }
        for start in folds.keys where NSLocationInRange(start, chars) || start == chars.location {
            guard let pill = foldPillRect(forHeadingAt: start)?.offsetBy(dx: origin.x, dy: origin.y) else { continue }
            Theme.inlineCodeBackground.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            Theme.secondary.setFill()
            for i in 0..<3 {
                let d: CGFloat = 3
                NSBezierPath(ovalIn: NSRect(x: pill.midX - 7 + CGFloat(i) * 6 - d / 2 + 1, y: pill.midY - d / 2, width: d, height: d)).fill()
            }
        }
    }

    /// Rounded background behind each line segment of an attributed run (inline code, highlights).
    private func drawPills(_ key: NSAttributedString.Key, _ color: NSColor, in chars: NSRange,
                           ts: NSTextStorage, tc: NSTextContainer, origin: NSPoint) {
        ts.enumerateAttribute(key, in: chars, options: []) { value, r, _ in
            guard value != nil, !isFolded(r.location) else { return }
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
