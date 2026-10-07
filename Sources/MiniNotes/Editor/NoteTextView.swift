import AppKit
import Carbon.HIToolbox

final class NoteTextView: NSTextView {
    var onEscape: (() -> Void)?
    var placeholder = "Start writing…"

    private var mdLayout: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    /// 1 indent · 2 bullet · 3 gap · 4 task box · 5 number · 6 delimiter · 7 gap · 8 quote
    private static let listRE = re(#"^([ \t]*)(?:([-*+])([ \t]+)(\[[ xX]\](?:[ \t]+|$))?|(\d{1,9})([.)])([ \t]+)|(>[ \t]?))"#)
    private static let headingPrefixRE = re(#"^#{1,6}[ \t]+$"#)
    private static let blockRE = re(#"^([ \t]*)(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\](?:[ \t]+|$)|[-*+][ \t]+|\d{1,9}[.)][ \t]+)?"#)
    private static let taskRE = re(#"^[ \t]*[-*+][ \t]+\[([ xX])\]"#)

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if (textStorage?.length ?? 0) == 0, !hasMarkedText() {
            let font = (typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 15)
            (placeholder as NSString).draw(at: textContainerOrigin,
                                           withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    override func didChangeText() {
        super.didChangeText()
        if (textStorage?.length ?? 0) < 2 { needsDisplay = true }
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), !hasMarkedText() {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command, .shift] {
            switch Int(event.keyCode) {
            case kVK_ANSI_7: formatNumberedList(nil); return true
            case kVK_ANSI_8: formatBulletList(nil); return true
            case kVK_ANSI_9: formatChecklist(nil); return true
            default: break
            }
        }
        if flags == .command, event.keyCode == UInt16(kVK_Return) {
            toggleTask(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// `[] `, `[ ] ` or `[x] ` typed at the start of a line becomes a markdown task (`- [ ] `).
    private static let taskShortcutRE = re(#"^([ \t]*)(?:[-*+][ \t]+)?\[([ xX]?)\] $"#)

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard (string as? String) == " " || (string as? NSAttributedString)?.string == " ", !hasMarkedText() else { return }
        let ns = self.string as NSString
        let caret = selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let b = before as NSString
        guard let m = Self.taskShortcutRE.firstMatch(in: before, range: NSRange(location: 0, length: b.length)) else { return }
        let indent = b.substring(with: m.range(at: 1))
        let mark = b.substring(with: m.range(at: 2)).lowercased() == "x" ? "x" : " "
        let task = indent + "- [\(mark)] "
        guard task != before else { return }
        // Its own undo step: ⌘Z right after brings back the literal "[] ".
        breakUndoCoalescing()
        replace(NSRange(location: lineStart, length: b.length), with: task,
                select: NSRange(location: lineStart + (task as NSString).length, length: 0))
        breakUndoCoalescing()
    }

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard !hasMarkedText(), let ts = textStorage else { return super.insertNewline(sender) }
        let ns = string as NSString
        var s = 0, e = 0, ce = 0
        ns.getLineStart(&s, end: &e, contentsEnd: &ce, for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: NSRange(location: s, length: ce - s))
        let ln = line as NSString
        let inCode = ts.length > 0 && ts.attribute(.mdCodeBlock, at: min(s, ts.length - 1), effectiveRange: nil) != nil
            && s < ts.length

        if !inCode, let m = Self.listRE.firstMatch(in: line, range: NSRange(location: 0, length: ln.length)),
           sel.location - s >= m.range.length {
            let indent = ln.substring(with: m.range(at: 1))
            let rest = ln.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty, sel.length == 0 {
                // Enter on an empty item: outdent, or end the list.
                if !indent.isEmpty {
                    outdent(lineStart: s, indent: indent)
                } else {
                    replace(NSRange(location: s, length: ce - s), with: "", select: NSRange(location: s, length: 0))
                }
                return
            }
            var next = indent
            if m.range(at: 2).location != NSNotFound {
                next += ln.substring(with: m.range(at: 2)) + ln.substring(with: m.range(at: 3))
                if m.range(at: 4).location != NSNotFound { next += "[ ] " }
            } else if m.range(at: 5).location != NSNotFound {
                let n = Int(ln.substring(with: m.range(at: 5))) ?? 0
                next += "\(n + 1)" + ln.substring(with: m.range(at: 6)) + ln.substring(with: m.range(at: 7))
            } else {
                next += "> "
            }
            insertText("\n" + next, replacementRange: sel)
            return
        }

        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        if !leading.isEmpty, sel.location - s >= (leading as NSString).length {
            insertText("\n" + leading, replacementRange: sel)
            return
        }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if selectionIsList() { shiftLines(by: 1) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if selectionIsList() { shiftLines(by: -1) } else { super.insertBacktab(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, !hasMarkedText() {
            let ns = string as NSString
            let ls = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: ls, length: sel.location - ls))
            let full = NSRange(location: 0, length: (before as NSString).length)
            if !before.isEmpty, let m = Self.listRE.firstMatch(in: before, range: full), m.range.length == full.length {
                // Backspace right after a list marker removes the marker, not just a space.
                let indentLen = m.range(at: 1).length
                if indentLen < full.length {
                    replace(NSRange(location: ls + indentLen, length: full.length - indentLen), with: "",
                            select: NSRange(location: ls + indentLen, length: 0))
                    return
                }
            } else if !before.isEmpty, Self.headingPrefixRE.firstMatch(in: before, range: full) != nil {
                replace(NSRange(location: ls, length: full.length), with: "", select: NSRange(location: ls, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let box = checkbox(at: p) {
            toggleCheckbox(box)
            return
        }
        if event.modifierFlags.contains(.command), let url = link(at: p) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if checkbox(at: p) != nil || (event.modifierFlags.contains(.command) && link(at: p) != nil) {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    private func charIndex(at p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let cp = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        let g = lm.glyphIndex(for: cp, in: tc, fractionOfDistanceThroughGlyph: nil)
        let ci = lm.characterIndexForGlyph(at: g)
        return ci < ts.length ? ci : nil
    }

    private func checkbox(at p: NSPoint) -> NSRange? {
        guard let ts = textStorage, let lm = mdLayout, let ci = charIndex(at: p) else { return nil }
        let cp = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        for i in max(0, ci - 2)...min(ts.length - 1, ci + 3) {
            var r = NSRange()
            guard ts.attribute(.mdCheckbox, at: i, longestEffectiveRange: &r,
                               in: NSRange(location: max(0, i - 3), length: min(7, ts.length - max(0, i - 3)))) != nil,
                  let rect = lm.checkboxRect(for: r) else { continue }
            if rect.insetBy(dx: -4, dy: -4).contains(cp) { return r }
        }
        return nil
    }

    private func link(at p: NSPoint) -> URL? {
        guard let ts = textStorage, let ci = charIndex(at: p),
              let s = ts.attribute(.mdLink, at: ci, effectiveRange: nil) as? String else { return nil }
        return URL(string: s.hasPrefix("www.") ? "https://" + s : s)
    }

    private func toggleCheckbox(_ box: NSRange) {
        let ns = string as NSString
        let inner = NSRange(location: box.location + 1, length: 1)
        let sel = selectedRanges
        replace(inner, with: ns.substring(with: inner) == " " ? "x" : " ")
        selectedRanges = sel
    }

    // MARK: - Editing helpers

    func replace(_ range: NSRange, with str: String, select sel: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: str) else { return }
        textStorage?.replaceCharacters(in: range, with: str)
        didChangeText()
        if let sel { setSelectedRange(sel) }
    }

    private func selectionIsList() -> Bool {
        let ns = string as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        guard let m = Self.listRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return false
        }
        return m.range(at: 8).location == NSNotFound
    }

    private func outdent(lineStart s: Int, indent: String) {
        let remove = indent.hasPrefix("\t") ? 1 : min(2, indent.prefix { $0 == " " }.count)
        guard remove > 0 else { return }
        let sel = selectedRange()
        replace(NSRange(location: s, length: remove), with: "",
                select: NSRange(location: max(s, sel.location - remove), length: sel.length))
    }

    private func shiftLines(by direction: Int) {
        let ns = string as NSString
        let sel = selectedRange()
        let pr = ns.paragraphRange(for: sel)
        var lines = ns.substring(with: pr).components(separatedBy: "\n")
        var firstDelta = 0, total = 0
        for i in lines.indices {
            if i == lines.count - 1, lines[i].isEmpty, lines.count > 1 { continue }
            var delta: Int
            if direction > 0 {
                lines[i] = "  " + lines[i]
                delta = 2
            } else {
                let n = lines[i].hasPrefix("\t") ? 1 : min(2, lines[i].prefix { $0 == " " }.count)
                lines[i] = String(lines[i].dropFirst(n))
                delta = -n
            }
            if i == 0 { firstDelta = delta }
            total += delta
        }
        let start = max(pr.location, sel.location + firstDelta)
        let newSel = sel.length == 0
            ? NSRange(location: start, length: 0)
            : NSRange(location: start, length: max(0, sel.length + total - firstDelta))
        replace(pr, with: lines.joined(separator: "\n"), select: newSel)
    }

    // MARK: - Inline formatting

    @objc func formatBold(_ sender: Any?) { toggleWrap("**") }
    @objc func formatItalic(_ sender: Any?) { toggleWrap("_") }
    @objc func formatStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func formatInlineCode(_ sender: Any?) { toggleWrap("`") }
    @objc func formatHighlight(_ sender: Any?) { toggleWrap("==") }

    private func toggleWrap(_ marker: String) {
        let ns = string as NSString
        let m = (marker as NSString).length
        var sel = selectedRange()

        // Trim surrounding whitespace from the selection (double-click often grabs a space).
        while sel.length > 0, isSpace(ns.character(at: sel.location)) { sel.location += 1; sel.length -= 1 }
        while sel.length > 0, isSpace(ns.character(at: NSMaxRange(sel) - 1)) { sel.length -= 1 }

        if sel.length == 0 {
            if let word = wordRange(at: sel.location, in: ns) {
                sel = word
            } else {
                replace(sel, with: marker + marker, select: NSRange(location: sel.location + m, length: 0))
                return
            }
        }
        let text = ns.substring(with: sel)
        let before = sel.location >= m ? ns.substring(with: NSRange(location: sel.location - m, length: m)) : ""
        let after = NSMaxRange(sel) + m <= ns.length ? ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) : ""

        if before == marker, after == marker {
            replace(NSRange(location: sel.location - m, length: sel.length + 2 * m), with: text,
                    select: NSRange(location: sel.location - m, length: sel.length))
        } else if sel.length >= 2 * m, text.hasPrefix(marker), text.hasSuffix(marker) {
            let inner = (text as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            replace(sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length))
        } else {
            replace(sel, with: marker + text + marker, select: NSRange(location: sel.location + m, length: sel.length))
        }
    }

    private func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A }

    private func isWordChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x27 /* ' */
    }

    private func wordRange(at loc: Int, in ns: NSString) -> NSRange? {
        var start = loc, end = loc
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isWordChar(ns.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    @objc func formatLink(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let text = ns.substring(with: sel)
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipURL = clip.flatMap { $0.hasPrefix("http") && !$0.contains(" ") ? $0 : nil }

        if text.isEmpty {
            let url = clipURL ?? ""
            replace(sel, with: "[](\(url))", select: NSRange(location: sel.location + 1, length: 0))
        } else if text.hasPrefix("http") {
            replace(sel, with: "[](\(text))", select: NSRange(location: sel.location + 1, length: 0))
        } else if let url = clipURL {
            let out = "[\(text)](\(url))"
            replace(sel, with: out, select: NSRange(location: sel.location + (out as NSString).length, length: 0))
        } else {
            let urlStart = sel.location + (text as NSString).length + 3
            replace(sel, with: "[\(text)](url)", select: NSRange(location: urlStart, length: 3))
        }
    }

    // MARK: - Block formatting

    private enum Block: Equatable { case heading(Int), bullet, ordered, task, quote }

    @objc func formatHeading1(_ sender: Any?) { toggleBlock(.heading(1)) }
    @objc func formatHeading2(_ sender: Any?) { toggleBlock(.heading(2)) }
    @objc func formatHeading3(_ sender: Any?) { toggleBlock(.heading(3)) }
    @objc func formatBulletList(_ sender: Any?) { toggleBlock(.bullet) }
    @objc func formatNumberedList(_ sender: Any?) { toggleBlock(.ordered) }
    @objc func formatChecklist(_ sender: Any?) { toggleBlock(.task) }
    @objc func formatQuote(_ sender: Any?) { toggleBlock(.quote) }

    private func kind(_ prefix: String) -> Block? {
        if prefix.isEmpty { return nil }
        if prefix.hasPrefix("#") { return .heading(prefix.filter { $0 == "#" }.count) }
        if prefix.hasPrefix(">") { return .quote }
        if prefix.contains("[") { return .task }
        if prefix.first?.isNumber == true { return .ordered }
        return .bullet
    }

    private func toggleBlock(_ target: Block) {
        let ns = string as NSString
        let sel = selectedRange()
        let pr = ns.paragraphRange(for: sel)
        var text = ns.substring(with: pr)
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { text.removeLast() }
        let lines = text.components(separatedBy: "\n")

        let parsed = lines.map { line -> (indent: String, kind: Block?, body: String) in
            let l = line as NSString
            guard let m = Self.blockRE.firstMatch(in: line, range: NSRange(location: 0, length: l.length)) else {
                return ("", nil, line)
            }
            let indent = l.substring(with: m.range(at: 1))
            let prefix = m.range(at: 2).location == NSNotFound ? "" : l.substring(with: m.range(at: 2))
            return (indent, kind(prefix), l.substring(from: m.range.length))
        }
        let meaningful = parsed.filter { !$0.body.isEmpty || $0.kind != nil }
        let removing = !meaningful.isEmpty && meaningful.allSatisfy { $0.kind == target }

        var number = 0
        let out = parsed.map { p -> String in
            if removing { return p.indent + p.body }
            if p.body.isEmpty, p.kind == nil, lines.count > 1 { return p.indent }
            number += 1
            switch target {
            case .heading(let level): return String(repeating: "#", count: level) + " " + p.body
            case .bullet: return p.indent + "- " + p.body
            case .ordered: return p.indent + "\(number). " + p.body
            case .task: return p.indent + "- [ ] " + p.body
            case .quote: return p.indent + "> " + p.body
            }
        }.joined(separator: "\n")

        let newLen = (out as NSString).length
        let newSel: NSRange
        if lines.count == 1 {
            let lineEnd = NSMaxRange(pr) - (trailingNewline ? 1 : 0)
            let fromEnd = max(0, lineEnd - NSMaxRange(sel))
            let loc = max(pr.location, pr.location + newLen - fromEnd - sel.length)
            newSel = NSRange(location: loc, length: min(sel.length, newLen))
        } else {
            newSel = NSRange(location: pr.location, length: newLen)
        }
        replace(NSRange(location: pr.location, length: (text as NSString).length), with: out, select: newSel)
    }

    @objc func toggleTask(_ sender: Any?) {
        let ns = string as NSString
        let lr = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: lr)
        if let m = Self.taskRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            let r = m.range(at: 1)
            let checked = (line as NSString).substring(with: r) != " "
            let sel = selectedRanges
            replace(NSRange(location: lr.location + r.location, length: 1), with: checked ? " " : "x")
            selectedRanges = sel
        } else {
            toggleBlock(.task)
        }
    }

    @objc func formatCodeBlock(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let pr = ns.paragraphRange(for: sel)
        var text = ns.substring(with: pr)
        if text.hasSuffix("\n") { text.removeLast() }
        let range = NSRange(location: pr.location, length: (text as NSString).length)
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            replace(range, with: "```\n\n```", select: NSRange(location: pr.location + 4, length: 0))
        } else {
            replace(range, with: "```\n" + text + "\n```",
                    select: NSRange(location: pr.location + 4, length: (text as NSString).length))
        }
    }
}
