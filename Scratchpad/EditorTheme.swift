import AppKit
import SwiftUI

/// Design tokens for the editor. The Figma values are the dark defaults; the
/// user's Settings and the panel's light/dark appearance produce variations
/// via `make(settings:colorScheme:)`.
struct EditorTheme: Equatable {

    // Type
    var font: NSFont = NSFont(name: "Monaco", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    var lineHeight: CGFloat = 17
    var tabWidth: Int = 4                       // spaces per tab stop
    /// Rich sheets use the system font (per the v2 Figma), one point larger
    /// than the mono size so the two modes feel the same weight.
    var richFont: NSFont = .systemFont(ofSize: 13)

    // Colour (dark defaults, from the Figma)
    var textColor = NSColor(srgbRed: 0xD9 / 255, green: 0xD9 / 255, blue: 0xD9 / 255, alpha: 1)
    var lineNumberColor = NSColor.white.withAlphaComponent(0.32)
    var backgroundColor = NSColor(white: 21 / 255, alpha: 1)   // #151515
    var backgroundOpacity: CGFloat = 0.88
    var hairlineTop = NSColor.black.withAlphaComponent(0.2)
    var hairlineBottom = NSColor.white.withAlphaComponent(0.2)
    var syntax = SyntaxPalette.dark

    // Geometry
    var cornerRadius: CGFloat = 8
    var horizontalInset: CGFloat = 12           // panel edge → line numbers
    var verticalInset: CGFloat = 8              // panel edge → first line
    var gutterGap: CGFloat = 11                 // line numbers → text

    static let `default` = EditorTheme()

    /// Height of one line of this font (ascender + descender), before our fixed line height.
    var fontHeight: CGFloat { ceil(font.ascender - font.descender) }

    /// Build the theme for the current settings and the panel's appearance.
    static func make(settings: AppSettings, colorScheme: ColorScheme) -> EditorTheme {
        var theme = EditorTheme()
        theme.font = settings.font
        theme.richFont = .systemFont(ofSize: settings.fontSize + 1)
        theme.lineHeight = ceil(settings.fontSize * settings.lineHeightMultiple)   // 12 × 1.4 → 17 (the Figma ratio)
        theme.backgroundOpacity = settings.editorOpacity

        let dark = colorScheme == .dark || settings.keepEditorDark
        if !dark {
            theme.textColor = NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
            theme.lineNumberColor = NSColor.black.withAlphaComponent(0.32)
            theme.backgroundColor = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1)
            theme.hairlineTop = NSColor.black.withAlphaComponent(0.1)
            theme.hairlineBottom = NSColor.white.withAlphaComponent(0.7)
            theme.syntax = .light
        }
        return theme
    }
}
