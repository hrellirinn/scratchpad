import AppKit
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }
    /// `nil` means "follow the system".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
}

/// All user preferences, in one observable object backed by `UserDefaults`.
///
/// Views bind to these properties directly; every `didSet` writes through to
/// defaults, so there's no separate "save" step and nothing to get out of sync.
@Observable
final class AppSettings {

    static let shared = AppSettings()
    static let maxSheets = 5
    static let fontSizeRange: ClosedRange<Double> = 9...32
    static let lineHeightRange: ClosedRange<Double> = 1.0...2.0

    /// The editor font as an `NSFont`, resolved from name + size.
    var font: NSFont { FontCatalog.font(name: fontName, size: fontSize) }

    /// PostScript name (e.g. "Monaco", "Menlo-Bold") — what the Font panel hands back.
    var fontName: String          { didSet { defaults.set(fontName, forKey: Keys.fontName) } }
    var fontSize: Double          { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    /// Line height as a multiple of the font size (CotEditor's "1.2 times").
    var lineHeightMultiple: Double { didSet { defaults.set(lineHeightMultiple, forKey: Keys.lineHeightMultiple) } }
    var sheetCount: Int           { didSet { defaults.set(sheetCount, forKey: Keys.sheetCount) } }
    var appearanceMode: AppearanceMode { didSet { defaults.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) } }
    var keepEditorDark: Bool      { didSet { defaults.set(keepEditorDark, forKey: Keys.keepEditorDark) } }
    var editorOpacity: Double     { didSet { defaults.set(editorOpacity, forKey: Keys.editorOpacity) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let fontName       = "fontName"
        static let fontSize       = "fontSize"
        static let lineHeightMultiple = "lineHeightMultiple"
        static let sheetCount     = "sheetCount"
        static let appearanceMode = "appearanceMode"
        static let keepEditorDark = "keepEditorDark"
        static let editorOpacity  = "editorOpacity"
    }

    private init() {
        // Defaults for a fresh install. `register` only fills in keys that
        // have never been written, so user choices always win.
        defaults.register(defaults: [
            Keys.fontName: "Monaco",
            Keys.fontSize: 12.0,
            Keys.lineHeightMultiple: 1.4,
            Keys.sheetCount: 5,
            Keys.appearanceMode: AppearanceMode.dark.rawValue,
            Keys.keepEditorDark: true,
            Keys.editorOpacity: 0.88,
        ])

        fontName       = defaults.string(forKey: Keys.fontName) ?? "Monaco"
        fontSize       = defaults.double(forKey: Keys.fontSize)
        lineHeightMultiple = defaults.double(forKey: Keys.lineHeightMultiple)
        sheetCount     = min(max(defaults.integer(forKey: Keys.sheetCount), 1), Self.maxSheets)
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearanceMode) ?? "") ?? .dark
        keepEditorDark = defaults.bool(forKey: Keys.keepEditorDark)
        editorOpacity  = defaults.double(forKey: Keys.editorOpacity)
    }
}

/// Font lookup shared by the editor and Settings.
enum FontCatalog {
    static func font(name: String, size: Double) -> NSFont {
        NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
