import AppKit

/// Languages the plain-text editor can colour. Rules are regular expressions,
/// which is how CotEditor and most lightweight editors do it: good for
/// scratch notes and pasted snippets, not a full parser.
enum SyntaxLanguage: String, CaseIterable, Identifiable {
    case plain, html, css, javascript, json, swift, markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain:      "Plain Text"
        case .html:       "HTML"
        case .css:        "CSS"
        case .javascript: "JavaScript"
        case .json:       "JSON"
        case .swift:      "Swift"
        case .markdown:   "Markdown"
        }
    }
}

/// What a matched piece of text is, which picks its colour from the theme.
enum TokenKind {
    case keyword, string, comment, number, tag, attribute, type
}

/// Colours for each token kind. Defaults are the dark set; `EditorTheme.make`
/// swaps in the light set when the editor is light.
struct SyntaxPalette: Equatable {
    var keyword   = NSColor(srgbRed: 0.69, green: 0.76, blue: 1.00, alpha: 1)   // periwinkle
    var string    = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.47, alpha: 1)   // amber
    var comment   = NSColor(white: 1, alpha: 0.42)
    var number    = NSColor(srgbRed: 0.60, green: 0.86, blue: 0.75, alpha: 1)   // mint
    var tag       = NSColor(srgbRed: 0.55, green: 0.78, blue: 1.00, alpha: 1)   // sky
    var attribute = NSColor(srgbRed: 0.85, green: 0.80, blue: 0.56, alpha: 1)   // sand
    var type      = NSColor(srgbRed: 0.93, green: 0.64, blue: 0.80, alpha: 1)   // orchid

    static let dark = SyntaxPalette()
    static let light = SyntaxPalette(
        keyword:   NSColor(srgbRed: 0.33, green: 0.30, blue: 0.80, alpha: 1),
        string:    NSColor(srgbRed: 0.76, green: 0.34, blue: 0.08, alpha: 1),
        comment:   NSColor(white: 0, alpha: 0.42),
        number:    NSColor(srgbRed: 0.05, green: 0.52, blue: 0.42, alpha: 1),
        tag:       NSColor(srgbRed: 0.10, green: 0.40, blue: 0.75, alpha: 1),
        attribute: NSColor(srgbRed: 0.55, green: 0.42, blue: 0.05, alpha: 1),
        type:      NSColor(srgbRed: 0.68, green: 0.20, blue: 0.52, alpha: 1)
    )

    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword:   keyword
        case .string:    string
        case .comment:   comment
        case .number:    number
        case .tag:       tag
        case .attribute: attribute
        case .type:      type
        }
    }
}

/// Paints syntax colours onto a text view as *temporary* attributes — layout-
/// only decoration that never enters the text storage, so saved files stay
/// exactly what was typed.
enum SyntaxHighlighter {

    private struct Rule {
        let regex: NSRegularExpression
        let kind: TokenKind
        let group: Int          // capture group to colour (0 = whole match)
    }

    private static var cache: [SyntaxLanguage: [Rule]] = [:]

    static func highlight(_ textView: NSTextView, language: SyntaxLanguage, palette: SyntaxPalette) {
        guard let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard language != .plain, full.length > 0 else { return }

        let text = storage.string
        // Rules are applied in order; later rules win, so comments come last.
        for rule in rules(for: language) {
            let color = palette.color(for: rule.kind)
            rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match, match.numberOfRanges > rule.group else { return }
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { return }
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
            }
        }
    }

    // MARK: - Rules

    private static func rules(for language: SyntaxLanguage) -> [Rule] {
        if let cached = cache[language] { return cached }
        let built = build(language)
        cache[language] = built
        return built
    }

    private static func rule(_ pattern: String, _ kind: TokenKind, group: Int = 0,
                             options: NSRegularExpression.Options = [.anchorsMatchLines]) -> Rule? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return Rule(regex: regex, kind: kind, group: group)
    }

    private static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    // Shared pieces
    private static let doubleQuoted = "\"(?:\\\\.|[^\"\\\\\\n])*\""
    private static let singleQuoted = "'(?:\\\\.|[^'\\\\\\n])*'"
    private static let backQuoted   = "`[^`]*`"
    private static let lineComment  = "//.*$"
    private static let blockComment = "/\\*[\\s\\S]*?\\*/"
    private static let number       = "\\b\\d+(?:\\.\\d+)?\\b"

    private static func build(_ language: SyntaxLanguage) -> [Rule] {
        var rules: [Rule?] = []
        switch language {
        case .plain:
            break

        case .javascript:
            rules += [
                rule(words("const let var function return if else for while do switch case break continue new class extends import export from default try catch finally throw async await this typeof instanceof in of yield static get set delete void"), .keyword),
                rule(words("null undefined true false NaN Infinity"), .type),
                rule(number, .number),
                rule(doubleQuoted, .string), rule(singleQuoted, .string), rule(backQuoted, .string),
                rule(lineComment, .comment), rule(blockComment, .comment),
            ]

        case .swift:
            rules += [
                rule(words("import let var func return if else guard for while repeat in switch case default break continue struct class enum protocol extension init deinit self Self super static final override private fileprivate internal public open throws throw try catch async await some any where is as typealias associatedtype inout mutating nonmutating lazy weak unowned defer do"), .keyword),
                rule(words("true false nil"), .type),
                rule("\\b[A-Z][A-Za-z0-9_]*\\b", .type),
                rule("@[A-Za-z_][A-Za-z0-9_]*", .attribute),
                rule(number, .number),
                rule(doubleQuoted, .string),
                rule(lineComment, .comment), rule(blockComment, .comment),
            ]

        case .css:
            rules += [
                rule("^[^{}\\n/][^{}\\n]*(?=\\s*\\{)", .tag),                 // selectors
                rule("([\\w-]+)\\s*:", .attribute, group: 1),                   // properties
                rule("@[\\w-]+", .keyword),                                       // @media, @import…
                rule("#[0-9a-fA-F]{3,8}\\b", .number),                            // hex colours
                rule("\\b\\d+(?:\\.\\d+)?(?:px|em|rem|%|vh|vw|vmin|vmax|s|ms|deg|fr|ch)?\\b", .number),
                rule("!important", .keyword),
                rule(doubleQuoted, .string), rule(singleQuoted, .string),
                rule(blockComment, .comment),
            ]

        case .html:
            rules += [
                rule("</?([A-Za-z][\\w-]*)", .tag, group: 1),                     // tag names
                rule("</?|/?>", .tag),                                             // brackets
                rule("\\b([\\w-]+)(?==)", .attribute, group: 1),                  // attributes
                rule(doubleQuoted, .string), rule(singleQuoted, .string),
                rule("&[a-zA-Z#0-9]+;", .number),                                  // entities
                rule("<!--[\\s\\S]*?-->", .comment),
            ]

        case .json:
            rules += [
                rule("(\"(?:\\\\.|[^\"\\\\])*\")\\s*:", .attribute, group: 1),   // keys
                rule(":\\s*(\"(?:\\\\.|[^\"\\\\])*\")", .string, group: 1),      // string values
                rule("-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", .number),
                rule(words("true false null"), .keyword),
            ]

        case .markdown:
            rules += [
                rule("^#{1,6} .*$", .keyword),                                     // headings
                rule("^\\s*(?:[-*+]|\\d+\\.) ", .number),                          // list markers
                rule("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__", .type),                  // bold
                rule("(?<![*\\w])\\*[^*\\n]+\\*(?!\\w)|(?<![_\\w])_[^_\\n]+_(?!\\w)", .attribute),   // italic
                rule("`[^`\\n]+`", .string),                                        // inline code
                rule("^```[\\s\\S]*?^```", .string, options: [.anchorsMatchLines]), // fenced code
                rule("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", .tag),                      // links
                rule("^>.*$", .comment),                                            // quotes
            ]
        }
        return rules.compactMap { $0 }
    }
}
