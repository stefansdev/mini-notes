import AppKit

/// Converts note markdown to HTML (and RTF) so copies paste formatted into Slack, Mail, Docs and Notion.
/// The plain-text markdown stays on the pasteboard too, so code editors and terminals still get markdown.
enum RichText {
    @MainActor
    static func addRichTypes(markdown: String, to pb: NSPasteboard) {
        let html = self.html(markdown)
        pb.addTypes([.html, .rtf], owner: nil)
        pb.setString(html, forType: .html)
        if let rtf = rtf(fromHTML: html) { pb.setData(rtf, forType: .rtf) }
    }

    /// Replaces the pasteboard with markdown (plain) + HTML + RTF.
    @MainActor
    static func copy(markdown: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setString(markdown, forType: .string)
        addRichTypes(markdown: markdown, to: pb)
    }

    @MainActor
    private static func rtf(fromHTML html: String) -> Data? {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(data: data, options: [
                  .documentType: NSAttributedString.DocumentType.html,
                  .characterEncoding: String.Encoding.utf8.rawValue,
              ], documentAttributes: nil) else { return nil }
        return try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: - Markdown → HTML

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let headingRE = re(#"^(#{1,6})[ \t]+(.*)$"#)
    private static let ruleRE = re(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let listRE = re(#"^([ \t]*)(?:([-*+])|(\d{1,9})[.)])[ \t]+(?:\[([ xX])\][ \t]*)?(.*)$"#)
    private static let quoteRE = re(#"^ {0,3}>[ \t]?(.*)$"#)

    static func html(_ markdown: String) -> String {
        var out = ""
        var paragraph: [String] = []
        var quote: [String] = []
        var listStack: [(tag: String, indent: Int)] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { out += "<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>\n" }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { out += "<blockquote>" + quote.map(inline).joined(separator: "<br>") + "</blockquote>\n" }
            quote = []
        }
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { out += "</li></\(listStack.removeLast().tag)>\n" }
        }
        func flushAll() { flushParagraph(); flushQuote(); closeLists() }
        func match(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        }
        func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : (s as NSString).substring(with: r)
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                out += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                i += 1
                continue
            }
            if trimmed.isEmpty { flushAll(); i += 1; continue }

            if let m = match(headingRE, line) {
                flushAll()
                let level = group(m, 1, line)!.count
                out += "<h\(level)>" + inline(group(m, 2, line) ?? "") + "</h\(level)>\n"
            } else if match(ruleRE, line) != nil {
                flushAll()
                out += "<hr>\n"
            } else if let m = match(quoteRE, line) {
                flushParagraph(); closeLists()
                quote.append(group(m, 1, line) ?? "")
            } else if let m = match(listRE, line) {
                flushParagraph(); flushQuote()
                let indent = (group(m, 1, line) ?? "").replacingOccurrences(of: "\t", with: "    ").count
                let tag = group(m, 3, line) != nil ? "ol" : "ul"
                var body = inline(group(m, 5, line) ?? "")
                if let box = group(m, 4, line) { body = (box == " " ? "☐ " : "☑ ") + body }
                if let last = listStack.last, indent > last.indent {
                    out += "\n<\(tag)>"
                    listStack.append((tag, indent))
                } else {
                    while let last = listStack.last, indent < last.indent { out += "</li></\(listStack.removeLast().tag)>" }
                    if let last = listStack.last, last.tag == tag {
                        out += "</li>"
                    } else {
                        closeLists(to: max(0, listStack.count - 1))
                        out += "<\(tag)>"
                        listStack.append((tag, indent))
                    }
                }
                out += "<li>" + body
            } else {
                flushQuote(); closeLists()
                paragraph.append(trimmed)
            }
            i += 1
        }
        flushAll()
        return """
        <html><head><meta charset="utf-8"></head><body style="font-family: -apple-system, Helvetica, sans-serif; font-size: 14px;">
        \(out)</body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let inlineRules: [(NSRegularExpression, String)] = [
        (re(#"\[([^\]]+)\]\(([^)\s]+)\)"#), #"<a href="$2">$1</a>"#),
        (re(#"(?<!["=>])\b((?:https?://|www\.)[^\s<]*[^\s<.,;:!?)])"#), #"<a href="$1">$1</a>"#),
        (re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), "<strong>$2</strong>"),
        (re(#"(?<![*\\])\*(?![\s*])(.+?)(?<![\s*\\])\*(?!\*)"#), "<em>$1</em>"),
        (re(#"(?<![\w_\\])_(?![\s_])(.+?)(?<![\s_\\])_(?![\w_])"#), "<em>$1</em>"),
        (re(#"~~(?=\S)(.+?)(?<=\S)~~"#), "<del>$1</del>"),
        (re(#"==(?=\S)(.+?)(?<=\S)=="#), "<mark>$1</mark>"),
    ]
    private static let codeSpanRE = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)

    /// Inline markdown → HTML. Code spans are cut out first so nothing inside them is formatted.
    static func inline(_ text: String) -> String {
        let ns = text as NSString
        var codes: [String] = []
        var stripped = ""
        var last = 0
        for m in codeSpanRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            stripped += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            stripped += "\u{1}\(codes.count)\u{1}"
            codes.append("<code>" + escape(ns.substring(with: m.range(at: 2))) + "</code>")
            last = NSMaxRange(m.range)
        }
        stripped += ns.substring(from: last)
        var result = escape(stripped)
        for (regex, template) in inlineRules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                    withTemplate: template)
        }
        for (n, code) in codes.enumerated() {
            result = result.replacingOccurrences(of: "\u{1}\(n)\u{1}", with: code)
        }
        return result
    }
}
