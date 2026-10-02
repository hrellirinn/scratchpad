import AppKit
import SwiftUI

// MARK: - SwiftUI wrapper

/// The editor: an AppKit `NSTextView` presented to SwiftUI as an ordinary view.
///
/// Two modes, chosen per sheet:
///   - plain: monospaced, line-number gutter, tabs and auto-indent; `text` binding
///   - rich:  system font, bold/italic/underline/strike, bullets and checklists;
///            `richText` binding (an `NSAttributedString` — text *with* its styling)
///
/// Why AppKit here? SwiftUI's `TextEditor` has no gutter, no control over line
/// height, and no formatting API. `NSTextView` is the same engine TextEdit and
/// CotEditor are built on, and already knows how to be rich.
struct CodeEditor: NSViewRepresentable {

    @Binding var text: String
    @Binding var richText: NSAttributedString
    var format: SheetFormat
    /// Syntax colouring for plain sheets. Ignored in rich mode.
    var language: SyntaxLanguage = .plain

    /// Identifies *which* sheet is showing. When this changes we swap the whole
    /// document (and clear undo history) instead of treating it as an edit.
    var documentID: Int

    var theme: EditorTheme = .default

    /// Space kept clear above the text for the header band. The text starts
    /// below it but scrolls *under* it (the header blurs what passes beneath).
    var topInset: CGFloat = 0

    /// Lets the toolbar reach the text view, and mirrors formatting state back.
    var controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = IndentingTextView.make(theme: theme)
        textView.delegate = context.coordinator
        textView.onFormattingChanged = { [weak controller] in controller?.refresh() }

        let scrollView = FrostedScrollView(frame: .zero)
        scrollView.frostHeight = topInset
        scrollView.documentView = textView
        scrollView.drawsBackground = false          // our SwiftUI background shows through
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)

        // The gutter lives in the scroll view's "ruler" slot.
        let ruler = LineNumberRulerView(textView: textView, theme: theme)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.appliedTheme = theme
        context.coordinator.appliedFormat = format
        context.coordinator.appliedLanguage = language
        controller.textView = textView

        loadDocument(into: textView, scrollView: scrollView)
        context.coordinator.highlightNow()
        return scrollView
    }

    /// SwiftUI calls this whenever a binding, `documentID`, `format` or `theme` changes.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        controller.textView = textView

        let switchedSheet = context.coordinator.documentID != documentID
        let switchedFormat = context.coordinator.appliedFormat != format

        if switchedSheet || switchedFormat {
            context.coordinator.documentID = documentID
            context.coordinator.appliedFormat = format
            context.coordinator.appliedTheme = theme
            context.coordinator.appliedLanguage = language
            loadDocument(into: textView, scrollView: scrollView)
            textView.undoManager?.removeAllActions()
            if switchedSheet {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollToBeginningOfDocument(nil)
            }
            controller.refresh()
            context.coordinator.highlightNow()
            return
        }

        // Language or theme changed: repaint the colours.
        if context.coordinator.appliedLanguage != language {
            context.coordinator.appliedLanguage = language
            context.coordinator.highlightNow()
        }

        // Settings changed (font, colours, opacity…): restyle in place.
        if context.coordinator.appliedTheme != theme {
            context.coordinator.appliedTheme = theme
            textView.applyTheme(theme, rich: format == .rich)
            if let ruler = context.coordinator.ruler {
                ruler.theme = theme
                ruler.updateThickness()
                ruler.needsDisplay = true
            }
            context.coordinator.highlightNow()
        }

        // Content changed from outside the editor (rare). Our own keystrokes
        // arrive here too, but they compare equal and fall through.
        switch format {
        case .plain:
            if textView.string != text {
                let selection = textView.selectedRange()
                textView.string = text
                textView.applyTheme(theme, rich: false)
                let clamped = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
                textView.setSelectedRange(clamped)
                context.coordinator.ruler?.updateThickness()
            }
        case .rich:
            if !textView.attributedString().isEqual(to: richText) {
                let selection = textView.selectedRange()
                textView.textStorage?.setAttributedString(richText)
                textView.applyTheme(theme, rich: true)
                let clamped = NSRange(location: min(selection.location, richText.length), length: 0)
                textView.setSelectedRange(clamped)
            }
        }
    }

    /// Put the current sheet into the text view and configure the mode.
    private func loadDocument(into textView: IndentingTextView, scrollView: NSScrollView) {
        switch format {
        case .plain:
            textView.isRichText = false
            scrollView.rulersVisible = true
            textView.textContainerInset = NSSize(width: 6, height: theme.verticalInset)
            textView.string = text
            textView.applyTheme(theme, rich: false)
            (scrollView.verticalRulerView as? LineNumberRulerView)?.updateThickness()
        case .rich:
            textView.isRichText = true
            scrollView.rulersVisible = false
            textView.textContainerInset = NSSize(width: 12, height: theme.verticalInset)
            textView.textStorage?.setAttributedString(richText)
            textView.applyTheme(theme, rich: true)
        }
        scrollView.tile()
    }

    /// Receives the text view's delegate callbacks and pushes edits back into
    /// the SwiftUI binding (which reaches SheetStore, which schedules the save).
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var documentID: Int
        var appliedTheme: EditorTheme?
        var appliedFormat: SheetFormat?
        var appliedLanguage: SyntaxLanguage?
        weak var textView: IndentingTextView?
        weak var ruler: LineNumberRulerView?
        private var pendingHighlight: DispatchWorkItem?

        init(_ parent: CodeEditor) {
            self.parent = parent
            self.documentID = parent.documentID
        }

        /// Repaint syntax colours immediately (load, language or theme change).
        func highlightNow() {
            pendingHighlight?.cancel()
            guard let textView else { return }
            let language: SyntaxLanguage = parent.format == .plain ? parent.language : .plain
            SyntaxHighlighter.highlight(textView, language: language, palette: parent.theme.syntax)
        }

        /// While typing, wait for a short pause before repainting the whole text.
        private func scheduleHighlight() {
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            switch parent.format {
            case .plain:
                parent.text = textView.string
                ruler?.updateThickness()
                ruler?.needsDisplay = true
                if parent.language != .plain { scheduleHighlight() }
            case .rich:
                // Copy, so later edits in the view don't mutate what the store holds.
                parent.richText = textView.attributedString().copy() as! NSAttributedString
            }
            parent.controller.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
            parent.controller.refresh()
        }
    }
}

// MARK: - Lists

/// The two list styles. A list item is a paragraph that starts with the
/// marker text "\t<marker>\t" — the same convention TextEdit uses — plus a
/// paragraph style with a hanging indent so wrapped lines align with the text.
enum ListKind: Equatable {
    case bullet, checklist

    /// Bullets change glyph as they nest (• ◦ ▪, then repeat), like Notes.
    static let bulletMarkers = ["•", "◦", "▪"]
    static let checkedMarker = "☑"
    static let uncheckedMarker = "☐"

    func marker(level: Int) -> String {
        switch self {
        case .bullet:    Self.bulletMarkers[level % Self.bulletMarkers.count]
        case .checklist: Self.uncheckedMarker
        }
    }

    /// Indent per nesting level, in points.
    static let indentStep: CGFloat = 24
    static let maxLevel = 4
}

/// What a list marker at the start of a paragraph tells us.
struct ListMarker {
    let range: NSRange      // the whole "\t•\t"
    let kind: ListKind
    let checked: Bool
    let level: Int
}

struct FormattingState {
    var bold = false, italic = false, underline = false, strikethrough = false
    var list: ListKind?
}

// MARK: - Text view

/// `NSTextView` configured as a scratch editor: plain mode with auto-indent,
/// rich mode with inline styles, bullets and clickable checklists.
final class IndentingTextView: NSTextView {

    /// Called after a formatting change that didn't change the text itself
    /// (e.g. toggling bold with nothing selected), so the toolbar can update.
    var onFormattingChanged: (() -> Void)?

    // Theme-derived values kept for rich-mode edits.
    private var richFont: NSFont = .systemFont(ofSize: 13)
    private var richBaseParagraph = NSParagraphStyle.default
    private var baseTextColor: NSColor = .textColor
    private var checkedTextColor: NSColor = .secondaryLabelColor
    private var lineHeight: CGFloat = 17

    /// Builds the classic TextKit stack (storage → layout manager → container →
    /// view) explicitly, so the line-number gutter can query the layout manager.
    static func make(theme: EditorTheme) -> IndentingTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true       // soft-wrap at the view's width
        container.lineFragmentPadding = 0          // we manage horizontal insets ourselves
        layoutManager.addTextContainer(container)

        let textView = IndentingTextView(frame: NSRect.zero, textContainer: container)
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = NSView.AutoresizingMask.width

        // None of the "helpful" substitutions that mangle pasted code, URLs or commands.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Hide Apple Intelligence / Writing Tools affordances in this view.
        textView.writingToolsBehavior = NSWritingToolsBehavior.none

        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: theme.verticalInset)
        return textView
    }

    // MARK: Theme

    /// Apply font, colours and the fixed line height. In rich mode this keeps
    /// bold/italic and list indents and only normalises family, size and colour.
    func applyTheme(_ theme: EditorTheme, rich: Bool) {
        appliedTheme = theme
        lineHeight = theme.lineHeight
        baseTextColor = theme.textColor
        checkedTextColor = theme.textColor.withAlphaComponent(0.45)
        richFont = theme.richFont
        textColor = theme.textColor
        insertionPointColor = theme.textColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = theme.lineHeight
        paragraph.maximumLineHeight = theme.lineHeight

        guard rich else {
            font = theme.font
            paragraph.tabStops = []                                  // no preset stops…
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: theme.font]).width
            paragraph.defaultTabInterval = spaceWidth * CGFloat(theme.tabWidth)   // …just a repeating one
            defaultParagraphStyle = paragraph

            let attributes: [NSAttributedString.Key: Any] = [
                .font: theme.font,
                .foregroundColor: theme.textColor,
                .paragraphStyle: paragraph,
            ]
            typingAttributes = attributes
            if let storage = textStorage, storage.length > 0 {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
            return
        }

        // Rich mode
        font = theme.richFont
        richBaseParagraph = paragraph
        defaultParagraphStyle = paragraph
        typingAttributes = [.font: theme.richFont, .foregroundColor: theme.textColor, .paragraphStyle: paragraph]

        guard let storage = textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // Fonts: keep bold/italic, normalise family and size.
        storage.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) ?? []
            storage.addAttribute(.font, value: Self.font(richFont, with: traits), range: range)
        }
        // Paragraphs: keep list indents, normalise line height.
        storage.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let style = ((value as? NSParagraphStyle) ?? paragraph).mutableCopy() as! NSMutableParagraphStyle
            style.minimumLineHeight = theme.lineHeight
            style.maximumLineHeight = theme.lineHeight
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        // Colour: theme colour everywhere, dimmed on checked items; markers restyled.
        storage.addAttribute(.foregroundColor, value: theme.textColor, range: full)
        forEachParagraph { paragraphRange in
            guard let marker = marker(atParagraphStart: paragraphRange.location) else { return }
            if marker.checked {
                storage.addAttribute(.foregroundColor, value: checkedTextColor, range: paragraphRange)
            }
            styleMarker(marker)
        }
        storage.endEditing()
    }

    /// Markers get their own look: checkboxes are drawn larger than the text so
    /// they're easy to see and hit, and a ticked box takes the accent colour.
    private func styleMarker(_ marker: ListMarker) {
        guard let storage = textStorage else { return }
        let glyphRange = NSRange(location: marker.range.location + 1, length: 1)
        switch marker.kind {
        case .bullet:
            storage.addAttribute(.font, value: richFont, range: glyphRange)
            storage.addAttribute(.foregroundColor, value: baseTextColor, range: glyphRange)
        case .checklist:
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: richFont.pointSize * 1.35), range: glyphRange)
            storage.addAttribute(.foregroundColor,
                                 value: marker.checked ? NSColor.controlAccentColor : baseTextColor.withAlphaComponent(0.85),
                                 range: glyphRange)
        }
    }

    private static func font(_ base: NSFont, with traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
    }

    // MARK: Plain-mode behaviour

    /// Return: in plain mode start the new line with the same leading whitespace
    /// (CotEditor behaviour); in a rich list continue the list, or end it when
    /// Return is pressed on an empty item.
    override func insertNewline(_ sender: Any?) {
        if isRichText {
            if insertNewlineInList() { return }
            super.insertNewline(sender)
            return
        }

        let string = self.string as NSString
        let caret = selectedRange()
        let lineRange = string.lineRange(for: NSRange(location: caret.location, length: 0))

        var indent = ""
        var index = lineRange.location
        let limit = min(caret.location, NSMaxRange(lineRange))
        while index < limit {
            let ch = string.character(at: index)
            guard ch == 0x20 || ch == 0x09 else { break }      // space or tab
            indent.append(ch == 0x20 ? " " : "\t")
            index += 1
        }
        insertText("\n" + indent, replacementRange: caret)
    }

    /// Escape: hand it to the window, which closes the panel.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }

    /// Tab / Shift-Tab inside a list item nests or un-nests it; elsewhere Tab
    /// is just a tab character.
    override func insertTab(_ sender: Any?) {
        if isRichText, changeListLevel(by: +1) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if isRichText, changeListLevel(by: -1) { return }
        super.insertBacktab(sender)
    }

    /// Pasted rich text can bring its own fonts and colours; re-run the theme
    /// so it matches the sheet (bold/italic survive, everything else is normalised).
    override func paste(_ sender: Any?) {
        super.paste(sender)
        if isRichText, let theme = appliedTheme { applyTheme(theme, rich: true) }
    }
    private var appliedTheme: EditorTheme?

    // ⌘U from the Format menu arrives here; ⌘B / ⌘I arrive as `changeFont(_:)`,
    // which NSTextView already handles for rich text.
    override func underline(_ sender: Any?) { toggleStyle(.underlineStyle) }

    // MARK: Rich-mode formatting

    /// What's active at the cursor (or at the start of the selection).
    func formattingState() -> FormattingState {
        var state = FormattingState()
        guard isRichText, let storage = textStorage else { return state }
        let selection = selectedRange()
        let attributes: [NSAttributedString.Key: Any] =
            (selection.length == 0 || selection.location >= storage.length)
            ? typingAttributes
            : storage.attributes(at: selection.location, effectiveRange: nil)

        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            state.bold = traits.contains(.bold)
            state.italic = traits.contains(.italic)
        }
        state.underline = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
        state.strikethrough = ((attributes[.strikethroughStyle] as? Int) ?? 0) != 0

        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(selection.location, storage.length), length: 0))
        state.list = marker(atParagraphStart: paragraph.location)?.kind
        return state
    }

    /// Bold / italic: flip a font trait on the selection, or on what gets typed next.
    func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard isRichText, let storage = textStorage else { return }
        let selection = selectedRange()
        let currentFont = attributeAtCursor(.font) as? NSFont ?? richFont
        let turnOn = !currentFont.fontDescriptor.symbolicTraits.contains(trait)

        func converted(_ font: NSFont) -> NSFont {
            var traits = font.fontDescriptor.symbolicTraits
            if turnOn { traits.insert(trait) } else { traits.remove(trait) }
            return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }

        if selection.length == 0 {
            var attributes = typingAttributes
            attributes[.font] = converted(currentFont)
            typingAttributes = attributes
            onFormattingChanged?()
        } else {
            modifyAttributes(in: selection) {
                storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                    storage.addAttribute(.font, value: converted((value as? NSFont) ?? currentFont), range: range)
                }
            }
        }
    }

    /// Underline / strikethrough: on or off for the selection, or for typing.
    func toggleStyle(_ key: NSAttributedString.Key) {
        guard isRichText, let storage = textStorage else { return }
        let selection = selectedRange()
        let isOn = ((attributeAtCursor(key) as? Int) ?? 0) != 0
        let newValue: Int? = isOn ? nil : NSUnderlineStyle.single.rawValue

        if selection.length == 0 {
            var attributes = typingAttributes
            attributes[key] = newValue
            typingAttributes = attributes
            onFormattingChanged?()
        } else {
            modifyAttributes(in: selection) {
                if let newValue { storage.addAttribute(key, value: newValue, range: selection) }
                else { storage.removeAttribute(key, range: selection) }
            }
        }
    }

    /// Bullets / checklist on every paragraph touched by the selection. If they
    /// all already have this kind of list, remove it instead.
    func toggleList(_ kind: ListKind) {
        guard isRichText, let storage = textStorage else { return }
        let text = storage.string as NSString
        let selection = selectedRange()
        let paragraphs = text.paragraphRange(for: selection)

        var starts: [Int] = []
        var index = paragraphs.location
        while true {
            let range = text.paragraphRange(for: NSRange(location: index, length: 0))
            starts.append(range.location)
            if NSMaxRange(range) >= NSMaxRange(paragraphs) || range.length == 0 { break }
            index = NSMaxRange(range)
        }
        let removing = starts.allSatisfy { marker(atParagraphStart: $0)?.kind == kind }

        guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
        storage.beginEditing()
        for start in starts.reversed() {                    // back to front keeps earlier offsets valid
            let existing = marker(atParagraphStart: start)
            if removing {
                if let existing { storage.replaceCharacters(in: existing.range, with: "") }
                setParagraphStyle(richBaseParagraph, atParagraphStart: start)
                setParagraphColor(baseTextColor, atParagraphStart: start)
            } else {
                let level = existing?.level ?? 0
                let markerText = "\t\(kind.marker(level: level))\t"
                let attributes: [NSAttributedString.Key: Any] = [.font: richFont, .foregroundColor: baseTextColor]
                if let existing {
                    storage.replaceCharacters(in: existing.range, with: NSAttributedString(string: markerText, attributes: attributes))
                } else {
                    storage.insert(NSAttributedString(string: markerText, attributes: attributes), at: start)
                }
                setParagraphStyle(listParagraphStyle(level: level), atParagraphStart: start)
                setParagraphColor(baseTextColor, atParagraphStart: start)
                if let marker = marker(atParagraphStart: start) { styleMarker(marker) }
            }
        }
        storage.endEditing()
        didChangeText()
        // Keep the typing style in step with the paragraph the cursor is in.
        var attributes = typingAttributes
        attributes[.paragraphStyle] = removing ? richBaseParagraph : listParagraphStyle(level: 0)
        attributes[.foregroundColor] = baseTextColor
        attributes[.font] = richFont
        typingAttributes = attributes
    }

    /// Nest (+1) or un-nest (−1) every list item in the selection. Returns false
    /// if the selection isn't in a list, so the caller can fall back to a tab.
    @discardableResult
    private func changeListLevel(by delta: Int) -> Bool {
        guard let storage = textStorage else { return false }
        let text = storage.string as NSString
        let selection = selectedRange()
        let paragraphs = text.paragraphRange(for: selection)

        var starts: [Int] = []
        var index = paragraphs.location
        while true {
            let range = text.paragraphRange(for: NSRange(location: index, length: 0))
            starts.append(range.location)
            if NSMaxRange(range) >= NSMaxRange(paragraphs) || range.length == 0 { break }
            index = NSMaxRange(range)
        }
        guard starts.contains(where: { marker(atParagraphStart: $0) != nil }) else { return false }

        guard shouldChangeText(in: paragraphs, replacementString: nil) else { return true }
        storage.beginEditing()
        for start in starts.reversed() {
            guard let existing = marker(atParagraphStart: start) else { continue }
            let level = min(max(existing.level + delta, 0), ListKind.maxLevel)
            guard level != existing.level else { continue }
            let glyphRange = NSRange(location: existing.range.location + 1, length: 1)
            storage.replaceCharacters(in: glyphRange, with: existing.checked ? ListKind.checkedMarker : existing.kind.marker(level: level))
            setParagraphStyle(listParagraphStyle(level: level), atParagraphStart: start)
            if let marker = marker(atParagraphStart: start) { styleMarker(marker) }
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(selection)

        if let current = marker(atParagraphStart: text.paragraphRange(for: NSRange(location: selection.location, length: 0)).location) {
            var attributes = typingAttributes
            attributes[.paragraphStyle] = listParagraphStyle(level: current.level)
            typingAttributes = attributes
        }
        return true
    }

    /// Flip ☐ ↔ ☑ on a checklist item and dim/undim its text.
    func toggleCheckbox(atParagraphStart start: Int) {
        guard let storage = textStorage, let marker = marker(atParagraphStart: start), marker.kind == .checklist else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        let selection = selectedRange()
        guard shouldChangeText(in: paragraph, replacementString: nil) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: marker.range.location + 1, length: 1),
                                  with: marker.checked ? ListKind.uncheckedMarker : ListKind.checkedMarker)
        storage.addAttribute(.foregroundColor, value: marker.checked ? baseTextColor : checkedTextColor, range: paragraph)
        if let updated = self.marker(atParagraphStart: start) { styleMarker(updated) }
        storage.endEditing()
        didChangeText()
        setSelectedRange(selection)
    }

    /// Click on a checkbox toggles it; anywhere else behaves normally.
    override func mouseDown(with event: NSEvent) {
        if isRichText, let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 {
            var point = convert(event.locationInWindow, from: nil)
            point.x -= textContainerInset.width
            point.y -= textContainerInset.height
            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let text = storage.string as NSString
            if charIndex < text.length {
                let paragraph = text.paragraphRange(for: NSRange(location: charIndex, length: 0))
                if let marker = marker(atParagraphStart: paragraph.location), marker.kind == .checklist {
                    // Target = the marker column (indent to text start) on the item's first line.
                    let markerGlyph = layoutManager.glyphIndexForCharacter(at: paragraph.location + 1)
                    let line = layoutManager.lineFragmentRect(forGlyphAt: markerGlyph, effectiveRange: nil)
                    let left = CGFloat(marker.level) * ListKind.indentStep
                    let right = CGFloat(marker.level + 1) * ListKind.indentStep
                    if point.y >= line.minY, point.y < line.maxY, point.x >= left - 4, point.x < right {
                        toggleCheckbox(atParagraphStart: paragraph.location)
                        return
                    }
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Rich-mode helpers

    /// Return inside a list: continue it with a fresh (unchecked) marker, or end
    /// the list if the current item is empty. Returns false when not in a list.
    private func insertNewlineInList() -> Bool {
        guard let storage = textStorage else { return false }
        let text = storage.string as NSString
        let selection = selectedRange()
        let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        guard let marker = marker(atParagraphStart: paragraph.location) else { return false }

        let contentStart = NSMaxRange(marker.range)
        let content = text.substring(with: NSRange(location: contentStart, length: NSMaxRange(paragraph) - contentStart))
            .trimmingCharacters(in: .newlines)

        if content.isEmpty && selection.length == 0 {
            // Empty item + Return = leave the list.
            guard shouldChangeText(in: paragraph, replacementString: nil) else { return true }
            storage.beginEditing()
            storage.replaceCharacters(in: marker.range, with: "")
            setParagraphStyle(richBaseParagraph, atParagraphStart: paragraph.location)
            storage.endEditing()
            didChangeText()
            var attributes = typingAttributes
            attributes[.paragraphStyle] = richBaseParagraph
            attributes[.foregroundColor] = baseTextColor
            typingAttributes = attributes
            onFormattingChanged?()
            return true
        }

        var attributes = typingAttributes
        attributes[.paragraphStyle] = listParagraphStyle(level: marker.level)
        attributes[.foregroundColor] = baseTextColor
        attributes[.font] = richFont
        insertText(NSAttributedString(string: "\n\t\(marker.kind.marker(level: marker.level))\t", attributes: attributes),
                   replacementRange: selection)
        typingAttributes = attributes
        let newStart = (storage.string as NSString).paragraphRange(for: NSRange(location: selection.location + 1, length: 0)).location
        if let fresh = self.marker(atParagraphStart: newStart) {
            storage.beginEditing(); styleMarker(fresh); storage.endEditing()
        }
        return true
    }

    /// Hanging indent for list items: marker in the first 24 pt, text after it,
    /// wrapped lines aligned with the text.
    private func listParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = richBaseParagraph.mutableCopy() as! NSMutableParagraphStyle
        let step = ListKind.indentStep
        style.firstLineHeadIndent = step * CGFloat(level)
        style.headIndent = step * CGFloat(level + 1)
        style.tabStops = [NSTextTab(textAlignment: .left, location: step * CGFloat(level) + 6),
                          NSTextTab(textAlignment: .left, location: step * CGFloat(level + 1))]
        return style
    }

    /// Reads "\t•\t" / "\t☐\t" / "\t☑\t" at the start of a paragraph, if present.
    func marker(atParagraphStart start: Int) -> ListMarker? {
        guard let storage = textStorage else { return nil }
        let text = storage.string as NSString
        guard start + 3 <= text.length,
              text.character(at: start) == 0x09,
              text.character(at: start + 2) == 0x09 else { return nil }
        let range = NSRange(location: start, length: 3)
        // Nesting level comes from the paragraph's hanging indent.
        let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
        let level = max(0, Int((style?.headIndent ?? ListKind.indentStep) / ListKind.indentStep + 0.5) - 1)
        switch text.character(at: start + 1) {
        case 0x2022, 0x25E6, 0x25AA: return ListMarker(range: range, kind: .bullet, checked: false, level: level)   // • ◦ ▪
        case 0x2610: return ListMarker(range: range, kind: .checklist, checked: false, level: level)                 // ☐
        case 0x2611: return ListMarker(range: range, kind: .checklist, checked: true, level: level)                  // ☑
        default:     return nil
        }
    }

    private func attributeAtCursor(_ key: NSAttributedString.Key) -> Any? {
        guard let storage = textStorage else { return typingAttributes[key] }
        let selection = selectedRange()
        if selection.length == 0 || selection.location >= storage.length { return typingAttributes[key] }
        return storage.attribute(key, at: selection.location, effectiveRange: nil)
    }

    private func setParagraphStyle(_ style: NSParagraphStyle, atParagraphStart start: Int) {
        guard let storage = textStorage else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        if paragraph.length > 0 { storage.addAttribute(.paragraphStyle, value: style, range: paragraph) }
    }

    private func setParagraphColor(_ color: NSColor, atParagraphStart start: Int) {
        guard let storage = textStorage else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        if paragraph.length > 0 { storage.addAttribute(.foregroundColor, value: color, range: paragraph) }
    }

    private func forEachParagraph(_ body: (NSRange) -> Void) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        var index = 0
        while index < text.length {
            let range = text.paragraphRange(for: NSRange(location: index, length: 0))
            body(range)
            guard NSMaxRange(range) > index else { break }
            index = NSMaxRange(range)
        }
    }

    /// Attribute-only edits still need to go through the undo/notification
    /// path, so they're undoable and reach the store.
    private func modifyAttributes(in range: NSRange, _ body: () -> Void) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body()
        storage.endEditing()
        didChangeText()
    }
}

// MARK: - Line numbers

/// Draws line numbers in the scroll view's vertical ruler slot. Numbers are per
/// *logical* line (a soft-wrapped line keeps one number) and sit on the same
/// baseline as the text they label.
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?
    var theme: EditorTheme

    /// Where the text baseline sits inside a line fragment — learned from real
    /// lines and reused for the trailing empty line, which has no glyphs to ask.
    private var baselineInFragment: CGFloat?

    init(textView: NSTextView, theme: EditorTheme) {
        self.textView = textView
        self.theme = theme
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }          // match NSTextView's top-down coordinates

    private var numberAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.font, .foregroundColor: theme.lineNumberColor]
    }

    /// Gutter width: room for at least two digits, growing with the document.
    func updateThickness() {
        guard let textView else { return }
        let lineCount = max(1, textView.string.reduce(into: 1) { $0 += $1 == "\n" ? 1 : 0 })
        let digits = max(2, String(lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: numberAttributes).width
        let inset = textView.textContainerInset.width
        let thickness = ceil(theme.horizontalInset + digitWidth * CGFloat(digits) + theme.gutterGap - inset)
        if thickness != ruleThickness {
            ruleThickness = thickness
            scrollView?.tile()
        }
    }

    // No background fill — the dark panel behind us is the background — but
    // we must still erase, or numbers from a previous scroll position linger.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let text = textView.string as NSString
        let inset = textView.textContainerInset
        let attributes = numberAttributes
        let numberRight = ruleThickness - theme.gutterGap
        let textOrigin = convert(NSPoint.zero, from: textView)   // text view's origin, in our coordinates

        func drawNumber(_ number: Int, fragment: NSRect, baseline: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let top = textOrigin.y + inset.height + fragment.minY + baseline - theme.font.ascender
            label.draw(at: NSPoint(x: numberRight - size.width, y: top), withAttributes: attributes)
        }

        // Which characters are on screen?
        var visible = textView.visibleRect
        visible.origin.x -= inset.width
        visible.origin.y -= inset.height
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible line = 1 + newlines before it.
        var lineNumber = 1
        var searchRange = NSRange(location: 0, length: charRange.location)
        while true {
            let found = text.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
            if found.location == NSNotFound { break }
            lineNumber += 1
            let next = NSMaxRange(found)
            searchRange = NSRange(location: next, length: charRange.location - next)
        }

        // One number per logical line, drawn at that line's first fragment.
        var charIndex = text.lineRange(for: NSRange(location: charRange.location, length: 0)).location
        let end = NSMaxRange(charRange)
        while charIndex < end {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let baseline = layoutManager.location(forGlyphAt: glyphIndex).y
            baselineInFragment = baseline
            drawNumber(lineNumber, fragment: fragment, baseline: baseline)

            lineNumber += 1
            guard NSMaxRange(lineRange) > charIndex else { break }
            charIndex = NSMaxRange(lineRange)
        }

        // The trailing empty line (empty document, or text ending in a newline)
        // has no glyphs; the layout manager tracks it separately.
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fallback = (theme.lineHeight - theme.fontHeight) / 2 + theme.font.ascender
            drawNumber(lineNumber,
                       fragment: layoutManager.extraLineFragmentRect,
                       baseline: baselineInFragment ?? fallback)
        }
    }
}
