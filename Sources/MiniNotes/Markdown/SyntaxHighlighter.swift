import Foundation

enum TokenKind: Int, CaseIterable {
    case keyword, string, number, comment, type, function
}

/// Small, dependency-free code highlighter for fenced code blocks.
/// A hand-written scanner handles C-style languages (correct with strings, comments and escapes);
/// markup, CSS and YAML use a few regex passes.
enum SyntaxHighlighter {
    struct Grammar {
        enum Mode { case code, json, markup, css, yaml }
        var mode: Mode = .code
        var keywords: Set<String> = []
        var constants: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)? = nil
        var quotes: Set<unichar> = [0x22, 0x27]          // " '
        var multilineQuotes: Set<unichar> = []           // e.g. ` in JS and Go
        var tripleQuotes = false                         // """ / '''
        var caseInsensitive = false
        var variablePrefix: unichar? = nil               // $ in shell / PHP
        var decoratorPrefix: unichar? = nil              // @
    }

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let cStyleComments = (lines: ["//"], block: (open: "/*", close: "*/"))

    private static let swift = Grammar(
        keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as is try await async throws actor some any nonisolated isolated lazy weak unowned mutating override final required convenience get set willSet didSet indirect macro consume borrowing consuming"),
        constants: words("true false nil self Self super"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block,
        quotes: [0x22], tripleQuotes: true, decoratorPrefix: 0x40)

    private static let javascript = Grammar(
        keywords: words("break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof new return super switch throw try typeof var void while with yield let static async await of from as get set enum implements interface package private protected public type namespace declare abstract readonly keyof infer satisfies number string boolean any unknown never void object bigint symbol"),
        constants: words("true false null undefined NaN Infinity this"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block,
        multilineQuotes: [0x60], decoratorPrefix: 0x40)

    private static let python = Grammar(
        keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case print"),
        constants: words("True False None self cls"),
        lineComments: ["#"], tripleQuotes: true, decoratorPrefix: 0x40)

    private static let go = Grammar(
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
        constants: words("true false nil iota"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block, multilineQuotes: [0x60])

    private static let rust = Grammar(
        keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while macro_rules"),
        constants: words("true false self Self None Some Ok Err"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block, quotes: [0x22])

    private static let java = Grammar(
        keywords: words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized throw throws transient try void volatile while var record sealed permits yield"),
        constants: words("true false null this"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block, decoratorPrefix: 0x40)

    private static let kotlin = Grammar(
        keywords: words("as break class continue do else for fun if in interface is object package return super throw try typealias val var when while by catch constructor finally get import init set where abstract annotation companion const data enum external final infix inline inner internal lateinit open operator out override private protected public reified sealed suspend tailrec vararg"),
        constants: words("true false null this it"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block, tripleQuotes: true, decoratorPrefix: 0x40)

    private static let cFamily = Grammar(
        keywords: words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace template typename public private protected virtual override new delete using try catch throw constexpr noexcept explicit friend operator bool include define ifdef ifndef endif pragma import interface implementation end property nonatomic strong weak"),
        constants: words("true false NULL nullptr this self nil YES NO"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block, decoratorPrefix: 0x40)

    private static let csharp = Grammar(
        keywords: words("abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch throw try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await get set init record yield"),
        constants: words("true false null this"),
        lineComments: cStyleComments.lines, blockComment: cStyleComments.block, decoratorPrefix: 0x40)

    private static let ruby = Grammar(
        keywords: words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public puts"),
        constants: words("true false nil self"),
        lineComments: ["#"], decoratorPrefix: 0x40)

    private static let php = Grammar(
        keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty extends final finally fn for foreach function global goto if implements include instanceof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while yield"),
        constants: words("true false null this"),
        lineComments: ["//", "#"], blockComment: cStyleComments.block, variablePrefix: 0x24)

    private static let shell = Grammar(
        keywords: words("if then else elif fi case esac for while until do done in function return local export readonly declare unset shift exit source alias echo cd set trap eval exec sudo"),
        constants: words("true false"),
        lineComments: ["#"], variablePrefix: 0x24)

    private static let sql = Grammar(
        keywords: words("select from where and or not insert into values update set delete create table alter drop index view join left right inner outer full cross on as group by order having limit offset distinct union all case when then else end is primary key foreign references default constraint unique exists between like ilike in with returning asc desc begin commit rollback transaction if replace"),
        constants: words("true false null"),
        lineComments: ["--"], blockComment: cStyleComments.block, caseInsensitive: true)

    private static let lua = Grammar(
        keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
        constants: words("true false nil self"),
        lineComments: ["--"])

    private static let generic = Grammar(
        keywords: words("if else elif for while return function func fn def class struct enum interface type let var val const import from export new in of do switch case break continue try catch except throw raise async await public private static"),
        constants: words("true false null nil None True False undefined"),
        lineComments: ["//", "#"], blockComment: cStyleComments.block)

    private static let json = Grammar(mode: .json, constants: words("true false null"), quotes: [0x22])
    private static let markup = Grammar(mode: .markup)
    private static let css = Grammar(mode: .css)
    private static let yaml = Grammar(mode: .yaml, constants: words("true false null yes no on off"))

    private static let aliases: [String: Grammar] = {
        var m: [String: Grammar] = [:]
        func add(_ g: Grammar, _ names: String) { for n in names.split(separator: " ") { m[String(n)] = g } }
        add(swift, "swift")
        add(javascript, "js javascript jsx mjs cjs ts typescript tsx node deno")
        add(python, "py python python3 ipython")
        add(go, "go golang")
        add(rust, "rs rust")
        add(java, "java scala groovy dart")
        add(kotlin, "kt kotlin kts")
        add(cFamily, "c h cpp c++ cc cxx hpp objc objective-c objectivec m mm arduino")
        add(csharp, "cs csharp c#")
        add(ruby, "rb ruby")
        add(php, "php")
        add(shell, "sh bash zsh shell console fish terminal powershell ps1")
        add(sql, "sql mysql postgres postgresql sqlite psql")
        add(lua, "lua")
        add(json, "json jsonc json5")
        add(markup, "html xml svg vue xhtml plist htm")
        add(css, "css scss less sass")
        add(yaml, "yaml yml toml")
        return m
    }()

    /// The grammar for a fence info string (` ```swift `). No language → generic; prose languages → nil.
    static func grammar(for language: String?) -> Grammar? {
        guard let lang = language?.lowercased(), !lang.isEmpty else { return generic }
        if ["text", "txt", "plain", "plaintext", "md", "markdown", "diff"].contains(lang) { return nil }
        return aliases[lang] ?? generic
    }

    // MARK: - Highlighting

    static func highlight(_ ns: NSString, _ range: NSRange, language: String?, apply: (NSRange, TokenKind) -> Void) {
        guard range.length > 0, let g = grammar(for: language) else { return }
        switch g.mode {
        case .code, .json: scan(ns, range, g, apply)
        case .markup: regexPasses(ns, range, markupPasses, apply)
        case .css: regexPasses(ns, range, cssPasses, apply)
        case .yaml: regexPasses(ns, range, yamlPasses, apply)
        }
    }

    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }

    private static func isIdent(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    private static func matches(_ ns: NSString, _ i: Int, _ s: String, _ end: Int) -> Bool {
        let n = (s as NSString).length
        return i + n <= end && ns.substring(with: NSRange(location: i, length: n)) == s
    }

    private static func scan(_ ns: NSString, _ range: NSRange, _ g: Grammar, _ apply: (NSRange, TokenKind) -> Void) {
        let end = NSMaxRange(range)
        var i = range.location
        func emit(_ from: Int, _ to: Int, _ kind: TokenKind) { if to > from { apply(NSRange(location: from, length: to - from), kind) } }
        func lineEnd(_ from: Int) -> Int {
            var j = from
            while j < end, ns.character(at: j) != 0x0A { j += 1 }
            return j
        }

        outer: while i < end {
            let c = ns.character(at: i)

            if let bc = g.blockComment, matches(ns, i, bc.open, end) {
                let r = ns.range(of: bc.close, options: [], range: NSRange(location: i + 2, length: max(0, end - i - 2)))
                let stop = r.location == NSNotFound ? end : NSMaxRange(r)
                emit(i, stop, .comment); i = stop; continue
            }
            for lc in g.lineComments where matches(ns, i, lc, end) {
                // `#` only starts a comment at a word boundary (not `$#`, `a#b`).
                if lc == "#", i > range.location, !isSpace(ns.character(at: i - 1)) { break }
                let stop = lineEnd(i)
                emit(i, stop, .comment); i = stop; continue outer
            }
            if g.tripleQuotes, c == 0x22 || c == 0x27, i + 2 < end,
               ns.character(at: i + 1) == c, ns.character(at: i + 2) == c {
                let delim = String(repeating: Character(Unicode.Scalar(c)!), count: 3)
                let r = ns.range(of: delim, options: [], range: NSRange(location: i + 3, length: max(0, end - i - 3)))
                let stop = r.location == NSNotFound ? end : NSMaxRange(r)
                emit(i, stop, .string); i = stop; continue
            }
            if g.quotes.contains(c) || g.multilineQuotes.contains(c) {
                let multiline = g.multilineQuotes.contains(c)
                var j = i + 1
                while j < end {
                    let d = ns.character(at: j)
                    if d == 0x5C { j += 2; continue }               // escape
                    if d == c { j += 1; break }
                    if d == 0x0A, !multiline { break }
                    j += 1
                }
                j = min(j, end)
                var kind = TokenKind.string
                if g.mode == .json {
                    var k = j
                    while k < end, ns.character(at: k) == 0x20 || ns.character(at: k) == 0x09 { k += 1 }
                    if k < end, ns.character(at: k) == 0x3A { kind = .type }   // "key":
                }
                emit(i, j, kind); i = j; continue
            }
            if isDigit(c), i == range.location || !isIdent(ns.character(at: i - 1)) {
                var j = i + 1
                while j < end {
                    let d = ns.character(at: j)
                    if isIdent(d) || (d == 0x2E && j + 1 < end && isDigit(ns.character(at: j + 1))) { j += 1 } else { break }
                }
                emit(i, j, .number); i = j; continue
            }
            if let v = g.variablePrefix, c == v, i + 1 < end {
                var j = i + 1
                if ns.character(at: j) == 0x7B {                     // ${...}
                    while j < end, ns.character(at: j) != 0x7D, ns.character(at: j) != 0x0A { j += 1 }
                    j = min(j + 1, end)
                } else {
                    while j < end, isIdent(ns.character(at: j)) { j += 1 }
                }
                if j > i + 1 { emit(i, j, .type); i = j; continue }
            }
            if let d = g.decoratorPrefix, c == d, i + 1 < end, isIdentStart(ns.character(at: i + 1)) {
                var j = i + 1
                while j < end, isIdent(ns.character(at: j)) || ns.character(at: j) == 0x2E { j += 1 }
                emit(i, j, .keyword); i = j; continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < end, isIdent(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                let key = g.caseInsensitive ? word.lowercased() : word
                if g.keywords.contains(key) {
                    emit(i, j, .keyword)
                } else if g.constants.contains(key) {
                    emit(i, j, .number)
                } else if g.mode == .code {
                    var k = j
                    while k < end, ns.character(at: k) == 0x20 { k += 1 }
                    if k < end, ns.character(at: k) == 0x28 {         // name(
                        emit(i, j, .function)
                    } else if let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f), word.count > 1 {
                        emit(i, j, .type)
                    }
                }
                i = j; continue
            }
            i += 1
        }
    }

    // MARK: - Regex-based modes

    private typealias Pass = (NSRegularExpression, Int, TokenKind)   // regex, capture group, kind

    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// Later passes win, so comments and strings go last.
    private static let markupPasses: [Pass] = [
        (re(#"</?([A-Za-z][\w:.\-]*)"#), 1, .keyword),
        (re(#"<[^>]*?\s([\w:\-]+)(?==)"#), 1, .type),
        (re(#"\s([\w:\-]+)(?=\s*=\s*["'])"#), 1, .type),
        (re(#"&[#\w]+;"#), 0, .number),
        (re(#""[^"\n]*"|'[^'\n]*'"#), 0, .string),
        (re(#"<!--[\s\S]*?(?:-->|$)"#), 0, .comment),
    ]

    private static let cssPasses: [Pass] = [
        (re(#"(?m)^\s*([^{}\n:]+?)\s*(?=\{)"#), 1, .function),
        (re(#"([\w\-]+)\s*:(?!:)(?=[^;{}]*[;}\n])"#), 1, .type),
        (re(#"(?<![\w\-])-?\d*\.?\d+(?:px|em|rem|%|vh|vw|vmin|vmax|s|ms|deg|fr|ch|pt)?\b"#), 0, .number),
        (re(#"#[0-9a-fA-F]{3,8}\b"#), 0, .number),
        (re(#"@[\w\-]+|!important"#), 0, .keyword),
        (re(#""[^"\n]*"|'[^'\n]*'"#), 0, .string),
        (re(#"/\*[\s\S]*?(?:\*/|$)"#), 0, .comment),
    ]

    private static let yamlPasses: [Pass] = [
        (re(#"(?m)^\s*(?:-\s+)?([\w.\-/ ]+?|"[^"\n]*"|'[^'\n]*')\s*(?=:(?:\s|$))"#), 1, .type),
        (re(#"(?m)^\s*\[[^\]\n]+\]"#), 0, .type),                           // TOML tables
        (re(#"(?m)(?<=:|=)\s*(true|false|null|yes|no|on|off|~|-?\d[\d._]*(?:e[+-]?\d+)?)\s*$"#, .caseInsensitive), 1, .number),
        (re(#"(?m)^\s*(-)\s"#), 1, .keyword),
        (re(#""(?:[^"\\\n]|\\.)*"|'[^'\n]*'"#), 0, .string),
        (re(#"(?m)(?:^|\s)(#.*)$"#), 1, .comment),
    ]

    private static func regexPasses(_ ns: NSString, _ range: NSRange, _ passes: [Pass], _ apply: (NSRange, TokenKind) -> Void) {
        let text = ns.substring(with: range)
        let local = NSRange(location: 0, length: (text as NSString).length)
        for (regex, group, kind) in passes {
            for m in regex.matches(in: text, range: local) {
                let r = m.range(at: group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                apply(NSRange(location: r.location + range.location, length: r.length), kind)
            }
        }
    }
}
